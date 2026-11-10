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
  local loop, errors, claudecode, frame, terminal_opens

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

  it("A: Claude's handshake just before connection_timeout stops the timeout", function()
    send("/project/a.lua")
    run(9900)
    local claude = claude_connects()
    claude.handshake()
    run(1500)

    assert.same({ "a.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

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

  it("H: after a drop in the wait, the mention gets a whole connection_timeout for Claude to come back", function()
    send("/project/a.lua")
    run(9900)
    local first = claude_connects()
    first.handshake()
    run(50)
    first.drop()
    run(2000)
    assert.same({}, errors, "the timeout that ran before the handshake must not fire after it")

    local second = claude_connects()
    second.handshake()
    run(1500)

    assert.same({ "a.lua" }, names(second.received()))
    assert.same({}, errors)
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
    run(1500)

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

  it("C: a stop cancels a connection timeout whose callback already waits for the main loop", function()
    send("/project/old.lua")
    -- In the timer phase in which the timeout fires, before its callback runs: stop, start, and send again.
    at(10000, function()
      claudecode.stop()
      assert(claudecode.start(false))
      send("/project/new.lua")
    end)
    run(10000)
    assert.same({}, errors, "the old timeout must not clear the mention sent after the stop")

    run(10100)
    assert.equals(1, #errors)
    assert.matches("clearing 1 queued", errors[1])
    assert_no_lua_error()
  end)

  it("B: :ClaudeCodeStop resets the connection timeout", function()
    send("/project/old.lua")
    run(5000)
    claudecode.stop()
    assert(claudecode.start(false))
    send("/project/new.lua")
    run(9000)
    assert.same({}, errors, "a mention sent after a restart gets the whole connection_timeout")

    run(1100)
    assert.equals(1, #errors)
    assert.matches("Connection timeout", errors[1])
  end)

  it("B, control: the connection timeout runs from the first queued mention, not from the latest", function()
    send("/project/first.lua")
    run(8000)
    send("/project/second.lua")
    run(1900)
    assert.same({}, errors)

    run(200)
    assert.equals(1, #errors)
    assert.matches("clearing 2 queued", errors[1])
    assert.same({}, claudecode.state.mention_queue)
  end)

  it("B: after a connection timeout, a later mention times out with an error too", function()
    send("/project/first.lua")
    run(10100)
    assert.equals(1, #errors)

    send("/project/second.lua")
    run(10100)

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

  it("D: a connection timeout that fires as Claude completes its handshake leaves the queue to that Claude", function()
    send("/project/a.lua")
    run(9000)
    local claude = claude_connects()
    claude.upgrade()
    -- The 101 write completes in the timer phase in which connection_timeout fires, before the main loop runs.
    at(1000, claude.handshake_written)
    run(2000)

    assert.same({ "a.lua" }, names(claude.received()))
    assert.same({}, errors)
  end)

  it("G, control: a queued file outside the cwd keeps its absolute path, though it shares the cwd's prefix", function()
    send("/project2/a.lua")
    local claude = claude_connects()
    claude.handshake()
    run(1500)

    assert.same({ "/project2/a.lua" }, claude.received())
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

  it("G: a queued mention reaches Claude with the same cwd-relative path as a connected send", function()
    send("/project/src/queued.lua")
    local claude = claude_connects()
    claude.handshake()
    run(1500)
    send("/project/src/connected.lua")
    run(1000)

    assert.same({ "src/queued.lua", "src/connected.lua" }, claude.received())
  end)

  -- Random sequences of sends, connects, upgrades, handshakes, drops, CLOSE frames, stops, starts and waits, each
  -- checked against the promise: no client gets a mention twice or out of order or from before a stop, no Lua error,
  -- nothing left queued or a timer left running after a long wait, and every mention of a run without a stop either
  -- reached a client or was counted in a timeout error. The seeds are fixed, so a failure names the seed and the steps
  -- that reproduce it. FUZZ_SEEDS, FUZZ_STEPS and FUZZ_BASE run other sequences.
  local SEEDS = tonumber(os.getenv("FUZZ_SEEDS") or "300")
  local STEPS = tonumber(os.getenv("FUZZ_STEPS") or "30")
  local BASE_SEED = tonumber(os.getenv("FUZZ_BASE") or "1")

  local function id_of(path)
    return tonumber(path:match("f(%d+)%.lua$"))
  end

  local function play(seed)
    local rng = { state = seed * 2654435761 % 4294967296 }
    local function rand(n)
      rng.state = (rng.state * 1103515245 + 12345) % 2147483648
      return (math.floor(rng.state / 65536) % n) + 1
    end
    local trace = {}
    local function note(fmt, ...)
      table.insert(trace, string.format(fmt, ...))
    end

    local next_id = 0
    local accepted = {} -- id -> epoch
    local epoch = 0
    local clients = {} -- list of { claude=, phase="tcp"|"upgrading"|"open"|"dropped", epoch= }
    local violations = {}
    local function violate(msg)
      table.insert(violations, msg)
    end
    local function open_clients()
      local out = {}
      for _, c in ipairs(clients) do
        if c.phase ~= "dropped" and c.epoch == epoch then
          table.insert(out, c)
        end
      end
      return out
    end

    local function check_received()
      for ci, c in ipairs(clients) do
        local ids = {}
        local seen = {}
        for _, path in ipairs(c.claude.received()) do
          local id = id_of(path)
          if seen[id] then
            violate(("client %d received f%d twice"):format(ci, id))
          end
          seen[id] = true
          if #ids > 0 and id < ids[#ids] then
            violate(("client %d received f%d after f%d: out of order"):format(ci, id, ids[#ids]))
          end
          table.insert(ids, id)
          if accepted[id] ~= nil and accepted[id] < c.epoch then
            violate(("client %d (epoch %d) received f%d sent in epoch %d"):format(ci, c.epoch, id, accepted[id]))
          end
        end
      end
    end

    local ok_all, err_all = pcall(function()
      for _ = 1, STEPS do
        local r = rand(100)
        if r <= 28 then
          if claudecode.state.server then
            next_id = next_id + 1
            local path = ("/project/f%d.lua"):format(next_id)
            local ok, e = claudecode.send_at_mention(path, nil, nil, "fuzz")
            if ok then
              accepted[next_id] = epoch
            else
              violate("send refused while running: " .. tostring(e))
            end
            note("send f%d", next_id)
          else
            note("send skipped (stopped)")
          end
        elseif r <= 38 then
          if claudecode.state.server then
            local c = { claude = claude_connects(), phase = "tcp", epoch = epoch }
            table.insert(clients, c)
            note("connect #%d", #clients)
          end
        elseif r <= 48 then
          for _, c in ipairs(open_clients()) do
            if c.phase == "tcp" then
              c.claude.upgrade()
              c.phase = "upgrading"
              note("upgrade")
              break
            end
          end
        elseif r <= 60 then
          for _, c in ipairs(open_clients()) do
            if c.phase == "upgrading" then
              c.claude.handshake_written()
              c.phase = "open"
              note("handshake_written")
              break
            end
          end
        elseif r <= 68 then
          local oc = open_clients()
          if #oc > 0 then
            local c = oc[rand(#oc)]
            c.claude.drop()
            c.phase = "dropped"
            note("drop")
          end
        elseif r <= 72 then
          for _, c in ipairs(open_clients()) do
            if c.phase == "open" and c.claude.client.state == "connected" then
              c.claude.close()
              c.phase = "dropped" -- CLOSE sent; the server removes it on the scheduled on_close
              note("close-frame")
              break
            end
          end
        elseif r <= 75 then
          if claudecode.state.server then
            claudecode.stop()
            epoch = epoch + 1
            note("STOP")
          end
        elseif r <= 80 then
          if not claudecode.state.server then
            assert(claudecode.start(false))
            note("START")
          end
        else
          local choices = { 0, 10, 30, 60, 100, 300, 700, 2000, 5000, 10100 }
          local ms = choices[rand(#choices)]
          run(ms)
          note("run %d", ms)
        end
        check_received()
      end

      -- Settle: restart if stopped, let everything finish with no more actions.
      if not claudecode.state.server then
        assert(claudecode.start(false))
        note("START (settle)")
      end
      run(30000)
      note("run 30000 (settle)")
      check_received()

      if #loop.lua_errors > 0 then
        violate("lua errors: " .. table.concat(loop.lua_errors, " || "))
      end
      -- Liveness: nothing stuck.
      if #claudecode.state.mention_queue > 0 then
        violate("stuck queue: " .. #claudecode.state.mention_queue)
      end
      if claudecode.state.mention_timer ~= nil or claudecode.state.connection_timer ~= nil then
        violate(
          "timers left: mention="
            .. tostring(claudecode.state.mention_timer)
            .. " conn="
            .. tostring(claudecode.state.connection_timer)
        )
      end
      -- Accounting: every mention accepted after the last stop that no client got must be counted in a timeout error.
      local delivered = {}
      for _, c in ipairs(clients) do
        for _, path in ipairs(c.claude.received()) do
          delivered[id_of(path)] = true
        end
      end
      local undelivered = 0
      for id, ep in pairs(accepted) do
        if ep == epoch and not delivered[id] then
          undelivered = undelivered + 1
        end
      end
      local cleared = 0
      for _, e in ipairs(errors) do
        local n = e:match("clearing (%d+) queued")
        if n then
          cleared = cleared + tonumber(n)
        end
      end
      -- The errors count over the whole run, and a stop clears mentions without one: only a run with no stop compares.
      if epoch == 0 and cleared ~= undelivered then
        violate(("accounting: %d undelivered but %d reported as cleared"):format(undelivered, cleared))
      end
    end)
    if not ok_all then
      violate("driver error: " .. tostring(err_all))
    end
    return violations, trace
  end

  it("fuzz: random sends, connects, drops, closes, stops and starts keep the promise", function()
    local bad = {}
    for seed = BASE_SEED, BASE_SEED + SEEDS - 1 do
      -- A fresh plugin and loop for each seed.
      if claudecode.state.server then
        claudecode.stop()
      end
      loop.timers, loop.scheduled, loop.lua_errors, loop.now = {}, {}, {}, 0
      for k in pairs(errors) do
        errors[k] = nil
      end
      claudecode.state.mention_queue = {}
      if not claudecode.state.server then
        assert(claudecode.start(false))
      end
      run(0)
      local violations, trace = play(seed)
      if #violations > 0 then
        table.insert(bad, ("seed %d: %s\n    trace: %s"):format(seed, violations[1], table.concat(trace, "; ")))
        if #bad >= 5 then
          break
        end
      end
    end
    if #bad > 0 then
      error("\n" .. table.concat(bad, "\n"), 0)
    end
  end)
end)
