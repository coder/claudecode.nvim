--- When Claude disconnects, the server closes the diffs that client left pending (#248). Closing a diff changes
--- windows, which Neovim refuses in the command-line window (E11) and under textlock (E565), so the cleanup waits
--- until Neovim allows it.
require("tests.busted_setup")

describe("The cleanup after a Claude client disconnects", function()
  local server, tcp, closed, scheduled, timers, refusal
  local saved = {}
  local token = "test-token-0123456789"
  local upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    .. "x-claude-code-ide-authorization: "
    .. token
    .. "\r\n\r\n"

  before_each(function()
    for _, name in ipairs({
      "claudecode.server.handshake",
      "claudecode.server.client",
      "claudecode.server.tcp",
      "claudecode.server.init",
    }) do
      package.loaded[name] = nil
    end
    closed, scheduled, timers, refusal = {}, {}, {}, nil
    saved.diff = package.loaded["claudecode.diff"]
    package.loaded["claudecode.diff"] = {
      close_diffs_for_client = function(client_id, reason)
        table.insert(closed, { client_id, reason })
      end,
      close_pending_diffs = function() end,
    }
    saved.schedule, saved.defer_fn = vim.schedule, vim.defer_fn
    saved.set_current_win = vim.api.nvim_set_current_win
    vim.schedule = function(fn)
      table.insert(scheduled, fn)
    end
    vim.defer_fn = function(fn)
      table.insert(timers, fn)
    end
    vim.api.nvim_set_current_win = function(win)
      if refusal then
        error(refusal)
      end
      saved.set_current_win(win)
    end
    tcp = require("claudecode.server.tcp")
    server = require("claudecode.server.init")
    assert(server.start({ port_range = { min = 10000, max = 65535 } }, token))
  end)

  after_each(function()
    vim.schedule, vim.defer_fn = saved.schedule, saved.defer_fn
    vim.api.nvim_set_current_win = saved.set_current_win
    if server.state.server then
      server.stop()
    end
    package.loaded["claudecode.diff"] = saved.diff
  end)

  ---Run what waits for the main loop or for a timer, as Neovim would on its next loop turn.
  ---@param queue table[] scheduled or timers
  local function run(queue)
    local due = { unpack(queue) }
    for i = #queue, 1, -1 do
      queue[i] = nil
    end
    for _, fn in ipairs(due) do
      fn()
    end
  end

  ---A Claude client that completed its WebSocket handshake.
  local function claude_connects()
    tcp._handle_new_connection(server.state.server)
    local client = assert(server.state.server.clients["client_" .. _G.claudecode_clients_created])
    local handle, closing = client.tcp_handle, false
    function handle:write(_, callback)
      if callback then
        callback()
      end
    end
    function handle:close()
      closing = true
    end
    function handle:is_closing()
      return closing
    end
    handle._read_cb(nil, upgrade)
    assert.equals("connected", client.state)
    return client
  end

  it("closes the client's diffs on the next loop turn", function()
    local client = claude_connects()

    client.tcp_handle._read_cb(nil, nil)
    assert.same({}, closed)
    run(scheduled)

    assert.same({ { client.id, "client disconnected" } }, closed)
    assert.same({}, timers)
  end)

  it("waits while Neovim refuses window changes, and closes the client's diffs once it allows them", function()
    local client = claude_connects()
    refusal = "E11: Invalid in command-line window; <CR> executes, CTRL-C quits"

    client.tcp_handle._read_cb(nil, nil)
    run(scheduled)
    assert.same({}, closed)
    refusal = "E565: Not allowed to change text or change window"
    run(timers)
    assert.same({}, closed)

    refusal = nil
    run(timers)
    assert.same({ { client.id, "client disconnected" } }, closed)
    assert.same({}, timers)
  end)
end)
