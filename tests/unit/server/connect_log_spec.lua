--- The server says "Authenticated" about a client only after its handshake passed the token check. A TCP connection
--- carries no proof yet: any process on the machine can open one, and its handshake can still fail.
require("tests.busted_setup")

describe("The server's log of a connecting client", function()
  local server, tcp, logged
  local token = "test-token-0123456789"

  before_each(function()
    logged = {}
    -- A logger that keeps every line in order, so the tests can read what the server said and when.
    package.loaded["claudecode.logger"] = setmetatable({}, {
      __index = function(_, level)
        return function(component, ...)
          local words = {}
          for _, word in ipairs({ ... }) do
            words[#words + 1] = tostring(word)
          end
          logged[#logged + 1] = { level = level, component = component, text = table.concat(words, " ") }
        end
      end,
    })
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
  end)

  after_each(function()
    if server.state.server then
      server.stop()
    end
    -- Later specs load the real logger, and the server modules that hold this one.
    for _, name in ipairs({
      "claudecode.logger",
      "claudecode.server.handshake",
      "claudecode.server.client",
      "claudecode.server.tcp",
      "claudecode.server.init",
    }) do
      package.loaded[name] = nil
    end
  end)

  local function start(auth_token)
    assert(server.start({ port_range = { min = 10000, max = 65535 } }, auth_token))
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

  ---@param pattern string A Lua pattern, matched against the text of each line the server logged
  ---@return integer[] indexes The position of each match in the log
  local function lines_matching(pattern)
    local indexes = {}
    for index, line in ipairs(logged) do
      if line.text:find(pattern) then
        indexes[#indexes + 1] = index
      end
    end
    return indexes
  end

  it("does not say Authenticated when a client only connects over TCP", function()
    local client = connect(start(token))

    assert.same({}, lines_matching("Authenticated"), vim.inspect(logged))
    assert.equals(1, #lines_matching("client connected, awaiting authentication: " .. client.id))
  end)

  it("never says Authenticated about a client whose token is wrong", function()
    local tcp_server = start(token)
    local client = connect(tcp_server)

    client.tcp_handle._read_cb(nil, upgrade("wrong-token-0123456789"))

    assert.same({}, lines_matching("Authenticated"), vim.inspect(logged))
    assert.equals(1, #lines_matching("Rejected " .. client.id), vim.inspect(logged))
    assert.is_nil(tcp_server.clients[client.id], "the rejected client is gone")
  end)

  it("says Authenticated once, after the handshake accepted the token", function()
    local client = connect(start(token))

    client.tcp_handle._read_cb(nil, upgrade(token))

    local authenticated = lines_matching("Authenticated WebSocket client connected: " .. client.id)
    assert.equals(1, #authenticated, vim.inspect(logged))
    local accepted = lines_matching("Client authenticated successfully: " .. client.id)
    assert.equals(1, #accepted, vim.inspect(logged))
    assert.is_true(accepted[1] < authenticated[1], "the token check logs first: " .. vim.inspect(logged))
    assert.is_true(client.handshake_complete)
  end)

  it("keeps its no-auth line, and never says Authenticated, when the server has no token", function()
    local client = connect(start(nil))

    client.tcp_handle._read_cb(nil, upgrade("any-value"))

    assert.equals(1, #lines_matching("client connected %(no auth%): " .. client.id), vim.inspect(logged))
    assert.same({}, lines_matching("Authenticated"), vim.inspect(logged))
    assert.is_true(client.handshake_complete)
  end)
end)
