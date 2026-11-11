---@brief TCP server implementation using vim.loop
local client_manager = require("claudecode.server.client")

local M = {}

---@class TCPServer
---@field server table The vim.loop TCP server handle
---@field port number The port the server is listening on
---@field auth_token string|nil The authentication token for validating connections
---@field clients table<string, WebSocketClient> Table of connected clients
---@field on_message function Callback for WebSocket messages
---@field on_connect function Callback for new connections
---@field on_open function Callback for a client whose WebSocket handshake completed
---@field on_disconnect function Callback for client disconnections
---@field on_error fun(err_msg: string) Callback for the server's own errors, not a client's
---@field keepalive_timeout number|nil The window in milliseconds for a pong and for write progress: twice the ping interval, set by `start_ping_timer`
---@field pending_polls table<table, boolean>|nil The check and idle handles of each stall judgement that waits for the next poll: closed by `stop_server`

-- Seed Lua's PRNG exactly once per process. #282 removed the implicit seeding
-- that used to happen via utils.shuffle_array (math.randomseed(os.time())), which
-- left LuaJIT's fixed default seed in place -- so every fresh Neovim picked the
-- *same* starting port and parallel instances always collided (#283). Mixing in a
-- sub-second source avoids two instances launched in the same second seeding
-- identically. hrtime is guarded because some test stubs omit it.
local rng_seeded = false
local function ensure_rng_seeded()
  if rng_seeded then
    return
  end
  local jitter
  local ok, hr = pcall(function()
    return vim.loop and vim.loop.hrtime and vim.loop.hrtime()
  end)
  if ok and type(hr) == "number" then
    jitter = hr % 1000000
  else
    jitter = math.floor((os.clock() % 1) * 1000000)
  end
  math.randomseed((os.time() * 1000000) + jitter)
  rng_seeded = true
end

-- Iterate the port range exactly once, starting from a random offset and wrapping
-- around. Returns a closure rather than materializing the range: the default
-- 10000-65535 range is ~55k entries, and building/shuffling it on every startup
-- was the cost #282 set out to remove.
local function port_iterator(min_port, max_port)
  local port_count = max_port - min_port + 1
  if port_count <= 0 then
    return function()
      return nil
    end
  end
  ensure_rng_seeded()
  local start_offset = math.random(port_count) - 1
  local checked = -1
  return function()
    checked = checked + 1
    if checked >= port_count then
      return nil
    end
    return min_port + ((start_offset + checked) % port_count)
  end
end

---Find an available port using a best-effort bind probe.
---NOTE: this is only a pre-filter. A successful throwaway bind does NOT guarantee
---the port is free: libuv's bind() defers EADDRINUSE to listen()/connect(), so a
---port another process is actively listening on still passes this probe. The
---authoritative check is create_server's bind+listen with retry.
---@param min_port number Minimum port to try
---@param max_port number Maximum port to try
---@return number|nil port Available port number, or nil if none found
function M.find_available_port(min_port, max_port)
  assert(type(min_port) == "number", "min_port must be a number")
  assert(type(max_port) == "number", "max_port must be a number")

  if min_port > max_port then
    return nil
  end

  for port in port_iterator(min_port, max_port) do
    local test_server = vim.loop.new_tcp()
    if test_server then
      local success = test_server:bind("127.0.0.1", port)
      test_server:close()

      if success then
        return port
      end
    end
  end

  return nil
end

---Bind AND listen on a single fresh TCP handle, returning that same handle.
---Binding then listening on one socket (instead of probing a throwaway socket and
---re-binding) is what makes a busy port detectable: libuv's bind() defers
---EADDRINUSE to listen(), so the listen() call is the real test, and keeping the
---handle we listened on removes the probe/rebind TOCTOU window.
---@param server TCPServer The server object whose connection handler to wire up
---@param port number Port to bind and listen on
---@return table|nil handle The bound+listening TCP handle, or nil on failure
---@return string|nil error Error message if failed
---@return string|nil reason The libuv error alone, if bind or listen failed
function M._bind_and_listen(server, port)
  local handle = vim.loop.new_tcp()
  if not handle then
    return nil, "Failed to create TCP server"
  end

  local bind_success, bind_err = handle:bind("127.0.0.1", port)
  if not bind_success then
    handle:close()
    return nil, "Failed to bind to port " .. port .. ": " .. (bind_err or "unknown error"), bind_err
  end

  local listen_success, listen_err = handle:listen(128, function(err)
    if err then
      server.on_error("Listen error: " .. err)
      return
    end

    M._handle_new_connection(server)
  end)

  if not listen_success then
    handle:close()
    return nil, "Failed to listen on port " .. port .. ": " .. (listen_err or "unknown error"), listen_err
  end

  return handle, nil
end

---Create and start a TCP server
---@param config ClaudeCodeConfig Server configuration
---@param callbacks table Callback functions
---@param auth_token string|nil Authentication token for validating connections
---@return TCPServer|nil server The server object, or nil on error
---@return string|nil error Error message if failed
function M.create_server(config, callbacks, auth_token)
  local min_port = config.port_range.min
  local max_port = config.port_range.max

  -- Build the server object up front so the listen callback can close over it.
  local server = {
    server = nil,
    port = nil,
    auth_token = auth_token,
    clients = {},
    on_message = callbacks.on_message or function() end,
    on_connect = callbacks.on_connect or function() end,
    on_open = callbacks.on_open or function() end,
    on_disconnect = callbacks.on_disconnect or function() end,
    on_error = callbacks.on_error or function() end,
  }

  -- Walk candidate ports and bind+listen on each until one succeeds. Retrying
  -- here (rather than committing to a single pre-probed port) is what fixes #283:
  -- when several Neovim instances race for the same port, the losers just advance
  -- to the next candidate instead of giving up with EADDRINUSE.
  local last_reason
  local tried_any = false
  for port in port_iterator(min_port, max_port) do
    tried_any = true
    local handle, err, reason = M._bind_and_listen(server, port)
    if handle then
      server.server = handle
      server.port = port
      return server, nil
    end
    last_reason = reason or err
  end

  if not tried_any then
    return nil, "No available ports in range " .. min_port .. "-" .. max_port
  end
  -- Short, so that it fits the command line at 80 columns: Neovim shows it at startup. libuv's error starts with its
  -- code ("EADDRINUSE: address already in use"), and the code alone says why.
  local code = last_reason and last_reason:match("^(%u+):") or last_reason or "unknown error"
  return nil, string.format("No free port in %d-%d (%s)", min_port, max_port, code)
end

---Handle a new client connection
---@param server TCPServer The server object
function M._handle_new_connection(server)
  local client_tcp = vim.loop.new_tcp()
  if not client_tcp then
    server.on_error("Failed to create client TCP handle")
    return
  end

  local accept_success, accept_err = server.server:accept(client_tcp)
  if not accept_success then
    server.on_error("Accept error: " .. (accept_err or "unknown error"))
    client_tcp:close()
    return
  end

  -- Create WebSocket client wrapper
  local client = client_manager.create_client(client_tcp, server.keepalive_timeout)
  server.clients[client.id] = client

  -- Set up data handler
  client_tcp:read_start(function(err, data)
    -- A client's failure is reported only as its disconnect reason, which the server logs at debug level. The
    -- user cannot act on it, and the plugin shows each on_error line, so a long one stops Neovim at "Press ENTER".
    if err then
      M._disconnect_client(server, client, 1006, "Client read error: " .. err)
      return
    end

    if not data then
      -- EOF - client disconnected
      M._disconnect_client(server, client, 1006, "EOF")
      return
    end

    -- Any bytes show that Claude is alive and writing. A pong can wait behind more unread data than the socket holds,
    -- and one poll does not reach it, so the keepalive does not wait for the pong itself.
    client.ping_unanswered_since = nil

    -- Process incoming data
    client_manager.process_data(client, data, function(cl, message)
      server.on_message(cl, message)
    end, function(cl, code, reason)
      M._disconnect_client(server, cl, code, reason)
    end, function(cl, error_msg)
      M._disconnect_client(server, cl, 1006, "Client error: " .. error_msg)
    end, server.auth_token, server.on_open)
  end)

  -- Notify about the TCP connection. on_open follows once its WebSocket handshake completes.
  server.on_connect(client)
end

---Close the socket of a client that left the server, unless it is closing already or the write callback of its Close
---frame will close it: closing it now would cancel that frame.
---@param client WebSocketClient The client whose socket to close
local function release_socket(client)
  if client.close_pending or client.tcp_handle:is_closing() then
    return
  end
  client.tcp_handle:close()
end

---Disconnect a client and remove it from the server.
---This ensures `server.on_disconnect` is invoked for every disconnect path
---(EOF, read errors, protocol errors, timeouts), and only once per client.
---@param server TCPServer The server object
---@param client WebSocketClient The client to disconnect
---@param code number|nil WebSocket close code
---@param reason string|nil WebSocket close reason
function M._disconnect_client(server, client, code, reason)
  assert(type(server) == "table", "Expected server to be a table")
  local on_disconnect_type = type(server.on_disconnect)
  local on_disconnect_mt = on_disconnect_type == "table" and getmetatable(server.on_disconnect) or nil
  assert(
    on_disconnect_type == "function" or (on_disconnect_mt ~= nil and type(on_disconnect_mt.__call) == "function"),
    "Expected server.on_disconnect to be callable"
  )
  assert(type(server.clients) == "table", "Expected server.clients to be a table")
  assert(type(client) == "table", "Expected client to be a table")
  assert(type(client.id) == "string", "Expected client.id to be a string")
  if code ~= nil then
    assert(type(code) == "number", "Expected code to be a number")
  end
  if reason ~= nil then
    assert(type(reason) == "string", "Expected reason to be a string")
  end

  -- Idempotency: a client can hit multiple disconnect paths (e.g. CLOSE frame
  -- followed by a TCP EOF). Only notify/remove once.
  if not server.clients[client.id] then
    -- The server dropped this client already, perhaps by stopping before this event ran, and nothing else will close
    -- its socket.
    release_socket(client)
    return
  end

  server.on_disconnect(client, code, reason)
  M._remove_client(server, client)
end

---Remove a client from the server
---@param server TCPServer The server object
---@param client WebSocketClient The client to remove
function M._remove_client(server, client)
  if server.clients[client.id] then
    server.clients[client.id] = nil
    release_socket(client)
  end
end

---Drop a client that the ping timer gave up on, and report it at once. RFC 6455 reserves 1006, so the Close frame says
---1011, as other servers do for a keepalive timeout. The connection still ends without the client's Close frame, which
---is what 1006 means here. The socket does not wait for that frame: a Claude that stopped answering or reading may
---never read it, and the frame waits behind everything queued for it. Closing now drops the frame and the queue.
---@param server TCPServer The server object
---@param client WebSocketClient The client to drop
---@param close_reason string The reason in the Close frame
---@param disconnect_reason string The reason that `on_disconnect` gets, with the code 1006
local function drop_client(server, client, close_reason, disconnect_reason)
  client_manager.close_client(client, 1011, close_reason)
  client_manager.abandon_close_frame(client)
  M._disconnect_client(server, client, 1006, disconnect_reason)
end

---Send a message to a specific client
---@param server TCPServer The server object
---@param client_id string The client ID
---@param message string The message to send
---@param callback function|nil Optional callback
function M.send_to_client(server, client_id, message, callback)
  local client = server.clients[client_id]
  if not client then
    if callback then
      callback("Client not found: " .. client_id)
    end
    return
  end

  client_manager.send_message(client, message, callback)
end

---Broadcast a message to all connected clients
---@param server TCPServer The server object
---@param message string The message to broadcast
---@param on_written fun(written: integer)|nil When a client took the message: called once, after the last write
---  finished, with how many writes succeeded. A socket that fails during the write reports it only here.
---@return integer sent How many clients took the message: those whose state is "connected"
function M.broadcast(server, message, on_written)
  local sent, pending, written, dispatched, reported = 0, 0, 0, false, false
  local function finish()
    if dispatched and not reported and pending == 0 and sent > 0 then
      reported = true
      on_written(written)
    end
  end
  for _, client in pairs(server.clients) do
    if client.state == "connected" then
      sent = sent + 1
      if on_written then
        pending = pending + 1
        client_manager.send_message(client, message, function(err)
          pending = pending - 1
          if not err then
            written = written + 1
          end
          finish()
        end)
      else
        client_manager.send_message(client, message)
      end
    end
  end
  if on_written then
    dispatched = true
    finish()
  end
  return sent
end

---Get the number of connected clients
---@param server TCPServer The server object
---@return number count Number of connected clients
function M.get_client_count(server)
  local count = 0
  for _ in pairs(server.clients) do
    count = count + 1
  end
  return count
end

---Get information about all clients
---@param server TCPServer The server object
---@return table clients Array of client information
function M.get_clients_info(server)
  local clients = {}
  for _, client in pairs(server.clients) do
    table.insert(clients, client_manager.get_client_info(client))
  end
  return clients
end

---Run `fn` once, right after libuv polls its sockets the next time. libuv reports that a socket is writable again
---only in a poll phase, and it runs a check handle right after each poll phase, in every libuv version. A ping tick
---that Neovim runs after a main-loop block inside an I/O callback can run before that poll, so it cannot see the bytes
---that Claude read during the block: what runs here can. An idle handle keeps that poll from waiting for a timer or a
---socket. Both handles are closed once `fn` ran. `stop_server` closes those that did not run yet.
---@param server TCPServer The server object
---@param fn function
---@return boolean armed False when libuv could not create a handle, and `fn` will not run
local function after_next_poll(server, fn)
  local check = vim.loop.new_check()
  local idle = vim.loop.new_idle()
  if not check or not idle then
    if check then
      check:close()
    end
    if idle then
      idle:close()
    end
    return false
  end
  local handles = { check, idle }
  server.pending_polls = server.pending_polls or {}
  server.pending_polls[handles] = true
  idle:start(function() end)
  check:start(function()
    server.pending_polls[handles] = nil
    for _, handle in ipairs(handles) do
      handle:stop()
      handle:close()
    end
    fn()
  end)
  return true
end

---Close the handles of the polls that `fn` did not run after yet.
---@param server TCPServer The server object
local function close_pending_polls(server)
  local pending = server.pending_polls
  server.pending_polls = nil
  for handles in pairs(pending or {}) do
    for _, handle in ipairs(handles) do
      handle:stop()
      if not handle:is_closing() then
        handle:close()
      end
    end
  end
end

---Drop a client that answered its ping and whose write queue made no progress at two ticks in a row, unless the poll
---that just ran shows progress. A Claude whose reader is stuck can still answer each ping, so only its write queue
---shows it. The queue is Neovim's memory: it goes with the client. The tick can run before libuv reported the bytes
---that Claude read during a block, so the stall is judged once more right after the next poll, and only that judgement
---drops.
---@param server TCPServer The server object
---@param client WebSocketClient The client whose queue made no progress at two ticks in a row
local function judge_stall(server, client)
  if server.clients[client.id] ~= client or client.state ~= "connected" then
    return
  end
  if client_manager.sample_write_progress(client) then
    client.write_stalled = nil
    return
  end
  local time_since_drain = math.floor((vim.loop.now() - client.last_drain) / 1000)
  local queued_kb = math.floor(client.tcp_handle:get_write_queue_size() / 1024)
  require("claudecode.logger").one_line(
    "info",
    "server",
    string.format("Closed %s: not reading for %ds, %d KB queued", client.id, time_since_drain, queued_kb)
  )
  drop_client(server, client, "Not reading", "Write queue stalled")
end

---Drop each of `clients` that sent nothing since its oldest ping, for `limit` ms. It runs right after the poll phase that
---reads the sockets [after_next_poll], so every byte that reached a socket before the loop time of the check has been
---read. A timer tick cannot judge: libuv can run it before it reads the pong that Claude sent. That happens after a
---block in a check callback or an I/O read callback, and, with libuv 1.44 (bundled in Neovim 0.8), after a block in any
---callback. libuv 1.44 also runs the timers again at the end of a pass, so two ticks can run with no read between them.
---`vim.schedule` is no help either: Neovim runs its callbacks between two passes, so it can run one before the read.
---@param server TCPServer The server object
---@param clients WebSocketClient[] The clients that the ping timer pinged in one tick
---@param limit number Age in milliseconds of the oldest unanswered ping at which a client is dropped
local function judge_silence(server, clients, limit)
  local now = vim.loop.now()
  for _, client in ipairs(clients) do
    local since = client.ping_unanswered_since
    if server.clients[client.id] == client and client.state == "connected" and since and now - since >= limit then
      -- Client connection timed out - log at INFO level (this is expected behavior)
      require("claudecode.logger").one_line(
        "info",
        "server",
        string.format("Closed %s: no reply for %ds", client.id, math.floor((now - since) / 1000))
      )
      drop_client(server, client, "Keepalive timeout", "Connection timeout")
    end
  end
end

---Stop the TCP server
---@param server TCPServer The server object
function M.stop_server(server)
  close_pending_polls(server)

  -- Close all clients
  for _, client in pairs(server.clients) do
    client_manager.close_client(client, 1001, "Server shutting down")
  end

  -- Clear clients
  server.clients = {}

  -- Close server
  if server.server and not server.server:is_closing() then
    server.server:close()
  end
end

---Start a periodic ping task to keep connections alive.
---A tick pings every connected client and never drops one. A client whose oldest ping is `interval * 2.5` old is dropped
---at the first read of its socket after a tick [judge_silence], if the loop ran that read within `interval * 1.5` of the
---tick. A block longer than that restarts the count (the next tick is a wake). Any bytes read from a client clear its
---stamp, so a Claude that sends anything, also a large message before its pong, is not dropped. A Claude that sends
---nothing is dropped at the first read after its oldest ping is `interval * 2.5` old: 3 intervals after that ping when
---the ticks come on time, and as early as 2.5 when a tick runs late by less than `interval * 1.5`. The half interval
---keeps timer jitter from moving the drop. A client that answered is also judged for a stall of its write queue
---[judge_stall].
---@param server TCPServer The server object
---@param interval number Ping interval in milliseconds (default: 30000)
---@return table? timer The timer handle, or nil if creation failed
function M.start_ping_timer(server, interval)
  interval = interval or 30000 -- 30 seconds
  local last_run = vim.loop.now()
  -- The ticks since the last one that started a fresh stall window: see `fresh_start` below.
  local ticks_since_fresh = math.huge

  local timer = vim.loop.new_timer()
  if not timer then
    server.on_error("Failed to create ping timer")
    return nil
  end

  -- A client has this long to answer a ping, and to let libuv write some of its queue. A Close frame gets the same
  -- window (see `client.close_client`), and the clients accepted from now on carry it.
  local timeout = interval * 2
  server.keepalive_timeout = timeout

  timer:start(interval, interval, function()
    -- libuv caches the loop time when a pass starts and runs the timers of the pass with it. A callback that ran before
    -- this tick in the pass can have blocked since, or the machine can have slept in it. Read the clock again: a stale
    -- `now` hides a wake, and a ping stamped with it looks older than it is.
    vim.loop.update_time()
    local now = vim.loop.now()
    local elapsed = now - last_run

    -- Detect potential system sleep: timer interval was significantly exceeded
    -- Allow 50% grace period (e.g., 45s instead of 30s) to account for system load
    local is_wake_from_sleep = elapsed > (interval * 1.5)
    -- A wake tick gives each client a fresh stall window: Claude had no chance yet to read after the sleep, so the stall
    -- count starts again and this tick judges nothing. The next two ticks always count, wake ticks or not, because wake
    -- ticks that come again and again are a loop that stays blocked, not sleeps. A stalled client is then closed at the
    -- second of them, and no pattern of late ticks keeps it.
    ticks_since_fresh = ticks_since_fresh + 1
    local fresh_start = is_wake_from_sleep and ticks_since_fresh > 2
    if fresh_start then
      ticks_since_fresh = 0
    end

    if is_wake_from_sleep then
      -- After system sleep/wake, forget the pings that went unanswered and reset the write-progress timestamps to
      -- prevent false timeouts. This gives clients a fresh keepalive window since the time jump isn't their fault
      require("claudecode.logger").debug(
        "server",
        string.format(
          "Detected potential wake from sleep (%.1fs elapsed), resetting client keepalive timers",
          elapsed / 1000
        )
      )
      for _, client in pairs(server.clients) do
        if client.state == "connected" then
          client.ping_unanswered_since = nil
          if fresh_start then
            client.last_drain = now
            client.write_stalled = nil
          end
        end
      end
    end

    local pinged, stalled = {}, {}
    for _, client in pairs(server.clients) do
      if client.state == "connected" then
        -- Every tick samples the write queue, so that "two ticks in a row" are consecutive ticks, whether the client
        -- answered or not. A tick that starts a fresh stall window does not.
        local reading = fresh_start or client_manager.is_client_reading(client)
        -- A client answered if no ping of it waited for the whole window (local connections, so use standard timeout)
        local since = client.ping_unanswered_since
        local answered = since == nil or now - since < timeout
        client_manager.send_ping(client, "ping")
        client.ping_unanswered_since = since or now
        table.insert(pinged, client)
        -- Only a client that answered is dropped for a stall, and only after the next poll confirms it. A client that
        -- did not answer is dropped by the keepalive judgement, whatever its write queue shows.
        if answered and not reading then
          table.insert(stalled, client)
        end
      end
    end

    last_run = now

    if #pinged > 0 then
      local tick_time = now
      -- Neither judgement happens at the tick: see `judge_silence` and `judge_stall`. If libuv cannot create the handles,
      -- the clients wait for the next tick.
      after_next_poll(server, function()
        -- The keepalive judges only if the poll came at most `interval * 1.5` after the tick. After a longer block Neovim
        -- and Claude can have slept together, and Claude has had no time to answer: the next tick finds the same gap,
        -- takes it for a wake and starts over.
        if vim.loop.now() - tick_time <= interval * 1.5 then
          judge_silence(server, pinged, interval * 2.5)
        end
        for _, client in ipairs(stalled) do
          judge_stall(server, client)
        end
      end)
    end
  end)

  return timer
end

return M
