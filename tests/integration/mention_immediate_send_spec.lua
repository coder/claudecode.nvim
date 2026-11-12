-- Real-Neovim check that disable_broadcast_debouncing keeps the readiness wait. With it on, a send while the queue is
-- empty goes out at once. A Claude whose WebSocket handshake completed less than connection_wait_delay ms ago is
-- still starting up, so that send must wait, as a queued mention does. Busted's mock vim has no sockets, so under
-- busted this is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("disable_broadcast_debouncing and a Claude that just connected", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("disable_broadcast_debouncing and a Claude that just connected", function()
  local claudecode = require("claudecode")
  local uv = vim.uv or vim.loop
  local config_dir, real_config_dir, dir, path, client, inbox

  local function wait_for(what, condition)
    assert(vim.wait(5000, condition, 5), what)
  end

  local function mentions_received()
    local _, count = inbox:gsub('"at_mentioned"', "")
    return count
  end

  ---@return number ms Loop time since Claude's handshake, on the clock that stamps connected_at
  local function ms_since_handshake()
    for _, info in ipairs(require("claudecode.server.init").get_status().clients or {}) do
      if info.state == "connected" and info.connected_at then
        uv.update_time()
        return uv.now() - info.connected_at
      end
    end
    error("no connected client")
  end

  before_each(function()
    real_config_dir = vim.env.CLAUDE_CONFIG_DIR
    config_dir = vim.fn.tempname()
    vim.fn.mkdir(config_dir, "p")
    vim.env.CLAUDE_CONFIG_DIR = config_dir
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    path = dir .. "/a.txt"
    vim.fn.writefile({ "a" }, path)
    claudecode.setup({
      auto_start = false,
      log_level = "error",
      terminal = { provider = "none" },
      track_selection = false,
      disable_broadcast_debouncing = true,
    })
    assert.is_true(claudecode.start(false))
    inbox = ""
    client = uv.new_tcp()
    client:connect("127.0.0.1", claudecode.state.port, function(err)
      assert(not err, err)
      client:read_start(function(_, data)
        inbox = inbox .. (data or "")
      end)
      client:write(table.concat({
        "GET / HTTP/1.1",
        "Host: 127.0.0.1",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "x-claude-code-ide-authorization: " .. claudecode.state.auth_token,
        "",
        "",
      }, "\r\n"))
    end)
    wait_for("Claude completed its handshake", function()
      return inbox:find("^HTTP/1.1 101") ~= nil and claudecode.is_claude_connected()
    end)
  end)

  after_each(function()
    if client and not client:is_closing() then
      client:close()
    end
    pcall(claudecode.stop)
    vim.env.CLAUDE_CONFIG_DIR = real_config_dir
    vim.fn.delete(dir, "rf")
    vim.fn.delete(config_dir, "rf")
  end)

  it("a send right after the handshake reaches Claude only once connection_wait_delay has passed", function()
    local wait = claudecode.state.config.connection_wait_delay
    assert.is_true(claudecode.send_at_mention(path, nil, nil, "test"))
    local sent = ms_since_handshake()
    assert.is_true(sent < wait - 100, string.format("the send came %d ms after the handshake", sent))

    wait_for("Claude got the mention", function()
      return mentions_received() == 1
    end)
    local got = ms_since_handshake()
    assert.is_true(got >= wait, string.format("Claude got the mention %d ms after its handshake, before %d ms", got, wait))
  end)

  it("a send once Claude is ready still goes out at once, with nothing queued", function()
    vim.wait(claudecode.state.config.connection_wait_delay + 100)
    assert.is_true(claudecode.send_at_mention(path, nil, nil, "test"))
    assert.equals(0, #(claudecode.state.mention_queue or {}))
    assert.is_nil(claudecode.state.mention_timer)

    wait_for("Claude got the mention", function()
      return mentions_received() == 1
    end)
  end)
end)
