require("tests.busted_setup")

local client = require("claudecode.server.client")

describe("WebSocket client failed handshake", function()
  -- A plain HTTP request, the way a local port scanner probes for web servers.
  local PLAIN_GET = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: Go-http-client/1.1\r\nConnection: close\r\n\r\n"

  local original_schedule
  local scheduled

  before_each(function()
    scheduled = {}
    original_schedule = vim.schedule
    vim.schedule = function(fn)
      table.insert(scheduled, fn)
    end
  end)

  after_each(function()
    vim.schedule = original_schedule
  end)

  -- Behaves like a libuv TCP handle: closing one that is already closing raises.
  local function make_handle()
    local handle = { closes = 0, writes = {} }
    function handle:write(data, callback)
      table.insert(self.writes, data)
      if callback then
        callback()
      end
      return true
    end
    function handle:close()
      if self.closes > 0 then
        error("handle " .. tostring(self) .. " is already closing")
      end
      self.closes = self.closes + 1
    end
    function handle:is_closing()
      return self.closes > 0
    end
    return handle
  end

  local function noop() end

  local function run_scheduled()
    for _, fn in ipairs(scheduled) do
      fn()
    end
  end

  it("does not close the handle again when the peer hung up first", function()
    local handle = make_handle()
    local c = client.create_client(handle)

    client.process_data(c, PLAIN_GET, noop, noop, noop, nil)
    assert.matches("^HTTP/1.1 400", handle.writes[1])

    -- The peer reads the 400 and hangs up; tcp.lua's EOF teardown closes the handle
    -- before the scheduled close runs.
    handle:close()

    assert.has_no.errors(run_scheduled)
    assert.equals(1, handle.closes)
  end)

  it("closes the handle when the peer keeps the connection open", function()
    local handle = make_handle()
    local c = client.create_client(handle)

    client.process_data(c, PLAIN_GET, noop, noop, noop, nil)
    run_scheduled()

    assert.equals(1, handle.closes)
    assert.equals("closing", c.state)
  end)
end)
