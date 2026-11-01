--- The server logs from libuv callbacks, at any moment the user types. A line wider than the command line, or one with
--- a line break, stops Neovim at "Press ENTER" until the user presses a key.
require("tests.busted_setup")

describe("Server lines on the command line", function()
  local server, tcp, lines
  local saved = {}
  local token = "test-token-0123456789"

  before_each(function()
    -- Fresh modules, so the server logs through a logger at its default level, info.
    for _, name in ipairs({
      "claudecode.logger",
      "claudecode.server.handshake",
      "claudecode.server.client",
      "claudecode.server.tcp",
      "claudecode.server.init",
    }) do
      package.loaded[name] = nil
    end
    lines = {}
    saved.notify, saved.echo, saved.new_timer, saved.new_tcp =
      vim.notify, vim.api.nvim_echo, vim.loop.new_timer, vim.loop.new_tcp
    vim.notify = function(msg, level)
      table.insert(lines, { text = msg, level = level })
    end
    vim.api.nvim_echo = function(chunks)
      table.insert(lines, { text = chunks[1][1], level = vim.log.levels.INFO })
    end
    tcp = require("claudecode.server.tcp")
    server = require("claudecode.server.init")
  end)

  after_each(function()
    if server.state.server then
      server.stop()
    end
    vim.notify, vim.api.nvim_echo, vim.loop.new_timer, vim.loop.new_tcp =
      saved.notify, saved.echo, saved.new_timer, saved.new_tcp
  end)

  local function start()
    assert(server.start({ port_range = { min = 10000, max = 65535 } }, token))
    return server.state.server
  end

  -- What the listen callback does for each new connection. Returns the client the server made for it.
  local function connect(tcp_server)
    tcp._handle_new_connection(tcp_server)
    return assert(tcp_server.clients["client_" .. _G.claudecode_clients_created])
  end

  local function upgrade(auth)
    return "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
      .. "x-claude-code-ide-authorization: "
      .. auth
      .. "\r\n\r\n"
  end

  ---@return table line The one line the server showed, after checking that it fits one line of the command line
  local function only_line()
    assert.equals(1, #lines, vim.inspect(lines))
    local text = lines[1].text
    assert.is_nil(text:find("[\r\n]"), "a line break in: " .. text)
    local width = vim.fn.strdisplaywidth(text)
    assert.is_true(width <= vim.v.echospace, string.format("%d cells: %s", width, text))
    return lines[1]
  end

  it("shows a failed accept as one error line with the reason from libuv", function()
    local tcp_server = start()
    tcp_server.server.accept = function()
      return nil, "EMFILE: too many open files"
    end

    tcp._handle_new_connection(tcp_server)

    local line = only_line()
    assert.equals(vim.log.levels.ERROR, line.level)
    assert_contains(line.text, "EMFILE")
  end)

  it("shows a client with a wrong token as one warning line that names the client", function()
    local client = connect(start())

    client.tcp_handle._read_cb(nil, upgrade("wrong-token-0123456789"))

    local line = only_line()
    assert.equals(vim.log.levels.WARN, line.level)
    assert_contains(line.text, "Rejected " .. client.id .. ": Invalid")
  end)

  it("shows a plain HTTP request as one warning line", function()
    local client = connect(start())

    client.tcp_handle._read_cb(nil, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

    local line = only_line()
    assert.equals(vim.log.levels.WARN, line.level)
    assert_contains(line.text, "Rejected " .. client.id .. ": Missing")
  end)

  it("shows no error when a rejected client hangs up before the server closes it", function()
    local client = connect(start())
    local handle = client.tcp_handle
    local closed = false
    function handle:close()
      assert(not closed, "handle is already closing") -- what libuv raises
      closed = true
    end
    function handle:is_closing()
      return closed
    end
    local scheduled, schedule = {}, vim.schedule
    vim.schedule = function(fn)
      table.insert(scheduled, fn)
    end
    handle._read_cb(nil, upgrade("wrong-token-0123456789"))
    handle._read_cb(nil, nil) -- the client reads the 400 reply and hangs up
    vim.schedule = schedule

    for _, fn in ipairs(scheduled) do
      fn()
    end

    assert.is_true(closed)
    assert.equals(vim.log.levels.WARN, only_line().level)
  end)

  it("removes a rejected client from the server and closes its socket", function()
    local tcp_server = start()
    local client = connect(tcp_server)
    local closed = false
    client.tcp_handle.close = function()
      closed = true
    end
    client.tcp_handle.is_closing = function()
      return closed
    end

    client.tcp_handle._read_cb(nil, upgrade("wrong-token-0123456789"))

    assert.is_nil(tcp_server.clients[client.id])
    assert.is_true(closed)
  end)

  for _, write_error in ipairs({ false, "ECANCELED: operation canceled" }) do
    local outcome = write_error and "fails with " .. write_error or "succeeds"
    it("closes a rejected client's socket when the server stops and the reply write then " .. outcome, function()
      local tcp_server = start()
      local client = connect(tcp_server)
      local handle, written = client.tcp_handle, nil
      local closed = false
      function handle:write(_, callback)
        written = callback
      end
      function handle:close()
        closed = true
      end
      function handle:is_closing()
        return closed
      end
      handle._read_cb(nil, upgrade("wrong-token-0123456789"))

      tcp.stop_server(tcp_server)
      written(write_error or nil)

      assert.is_true(closed)
    end)
  end

  it("shows a server whose ports are all in use as one error line that names the range", function()
    package.loaded["claudecode"] = nil
    vim.loop.new_tcp = function()
      local handle = saved.new_tcp()
      handle.listen = function()
        return nil, "EADDRINUSE: address already in use"
      end
      return handle
    end
    local claudecode = require("claudecode")
    claudecode.setup({ auto_start = false, port_range = { min = 10000, max = 10000 } })
    lines = {}

    assert.is_false(claudecode.start(false))

    local line = only_line()
    assert.equals(vim.log.levels.ERROR, line.level)
    assert_contains(line.text, "10000-10000")
    assert_contains(line.text, "EADDRINUSE")
  end)

  -- Without colors (a notify plugin, or :messages read through execute()), only the text tells an error from info.
  it("names the level of a cut error and warning in plain text", function()
    local client = connect(start())
    client.tcp_handle._read_cb(nil, upgrade("wrong-token-0123456789"))
    tcp._handle_new_connection(setmetatable({
      server = {
        accept = function()
          return nil, "EMFILE: too many open files"
        end,
      },
    }, { __index = server.state.server }))

    assert.equals(2, #lines, vim.inspect(lines))
    assert.equals("[ClaudeCode] WARN: Rejected " .. client.id .. ": Invalid authentication token", lines[1].text)
    assert.equals("[ClaudeCode] ERROR: Accept error: EMFILE: too many open files", lines[2].text)
  end)

  it("keeps a handshake reply that fails to send off the screen", function()
    local client = connect(start())
    client.tcp_handle.write = function(_, _, callback)
      callback("EPIPE: broken pipe")
    end

    client.tcp_handle._read_cb(nil, upgrade(token))

    assert.same({}, lines)
  end)

  it("shows a keepalive timeout as one info line", function()
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
    local client = connect(start())
    client.tcp_handle._read_cb(nil, upgrade(token))
    assert.equals("connected", client.state)
    lines = {}
    client.last_pong = vim.loop.now() - 61000

    tick()

    local line = only_line()
    assert.equals(vim.log.levels.INFO, line.level)
    assert_contains(line.text, client.id)
  end)
end)
