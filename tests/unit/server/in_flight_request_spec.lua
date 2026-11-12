-- A request has no answer until its handler returns, and a blocking tool has no response sender before that. When
-- Neovim exits inside a handler, the handler never returns, so `server.stop` must answer the request: Claude gets one
-- answer for every call that reached the server, and `_handle_request` sends nothing after a stop that answered it.
require("tests.busted_setup")

describe("a request whose handler is still running when the server stops", function()
  local server, tcp, saved_stop_server, replies
  local client = { id = "in-flight-client" }

  local function request(id, method)
    return { jsonrpc = "2.0", id = id, method = method or "slow", params = {} }
  end

  before_each(function()
    package.loaded["claudecode.server.init"] = nil
    server = require("claudecode.server.init")
    tcp = require("claudecode.server.tcp")
    saved_stop_server = tcp.stop_server
    tcp.stop_server = function() end
    server.state.server = {} -- a running server, as far as stop can tell
    replies = {}
    server.send_response = function(_, id, result, error_data)
      replies[#replies + 1] = { id = id, result = result, error = error_data }
    end
  end)

  after_each(function()
    tcp.stop_server = saved_stop_server
  end)

  local function replies_for(id)
    local found = {}
    for _, reply in ipairs(replies) do
      if reply.id == id then
        found[#found + 1] = reply
      end
    end
    return found
  end

  it("answers the request once with -32603, and sends nothing when the handler returns", function()
    server.state.handlers.slow = function()
      server.stop() -- Neovim exits here: VimLeavePre runs inside the handler
      return { content = { { type = "text", text = "too late" } } }
    end

    server._handle_request(client, request(7))

    local answers = replies_for(7)
    assert.equals(1, #answers, "one answer for one request")
    assert.equals(-32603, answers[1].error.code)
    assert.is_nil(answers[1].result)
    assert.is_nil(next(server.state.in_flight))
  end)

  it("answers every request whose handler is running, the outer one too", function()
    server.state.handlers.inner = function()
      server.stop()
    end
    server.state.handlers.outer = function()
      server._handle_request(client, request(2, "inner"))
    end

    server._handle_request(client, request(1, "outer"))

    for _, id in ipairs({ 1, 2 }) do
      local answers = replies_for(id)
      assert.equals(1, #answers, "request " .. id .. " gets one answer")
      assert.equals(-32603, answers[1].error.code)
    end
    assert.equals(2, #replies)
  end)

  it("answers a finished request through its own return, and leaves nothing in flight", function()
    server.state.handlers.slow = function()
      return { content = { { type = "text", text = "done" } } }
    end

    server._handle_request(client, request(3))
    server.stop()

    assert.equals(1, #replies)
    assert.equals("done", replies[1].result.content[1].text)
    assert.is_nil(next(server.state.in_flight))
  end)

  it("answers a request whose handler raised once, and leaves nothing in flight", function()
    server.state.handlers.slow = function()
      error("boom")
    end

    server._handle_request(client, request(4))
    server.stop()

    assert.equals(1, #replies)
    assert.equals(-32603, replies[1].error.code)
    assert.is_nil(next(server.state.in_flight))
  end)

  it("sends nothing when no handler is running", function()
    assert.is_true(server.stop())

    assert.same({}, replies)
  end)
end)
