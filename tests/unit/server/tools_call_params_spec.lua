--- A tools/call with no string name is a malformed request, so the client gets -32602 "Invalid params" and plain text
--- in `data`, never a Lua error with a file path. An empty or unknown string name is a well-formed request for a tool
--- that does not exist (-32601), and a notification gets no answer.
require("tests.busted_setup")

describe("tools/call without a string name", function()
  local server, tcp, original, replies

  before_each(function()
    package.loaded["claudecode.server.init"] = nil
    server = require("claudecode.server.init")
    server.register_handlers()
    tcp = require("claudecode.server.tcp")
    original = {
      server = server.state.server,
      send_to_client = tcp.send_to_client,
      decode = vim.json.decode,
      encode = vim.json.encode,
    }
    server.state.server = {}
    tcp.send_to_client = function() end
    vim.json.decode = _G.json_decode
    replies = {}
    vim.json.encode = function(value)
      table.insert(replies, value)
      return ""
    end
  end)

  after_each(function()
    server.state.server = original.server
    tcp.send_to_client = original.send_to_client
    vim.json.decode = original.decode
    vim.json.encode = original.encode
  end)

  local function send(payload)
    server._handle_message({ id = "test_client" }, payload)
  end

  for _, case in ipairs({
    { label = "no params", request = '{"jsonrpc":"2.0","id":6,"method":"tools/call"}' },
    { label = "empty params", request = '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{}}' },
    { label = "a list as params", request = '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":[]}' },
    {
      label = "arguments and no name",
      request = '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"arguments":{}}}',
    },
    { label = "a number as the name", request = '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":5}}' },
    { label = "a list as the name", request = '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":[1]}}' },
    {
      label = "a boolean as the name",
      request = '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":true}}',
    },
  }) do
    it("answers -32602 with its own id for " .. case.label, function()
      send(case.request)

      assert.equals(1, #replies)
      assert.equals(6, replies[1].id)
      assert.is_nil(replies[1].result)
      assert.same({
        code = -32602,
        message = "Invalid params",
        data = "Missing or invalid parameter: name (a string is required)",
      }, replies[1].error)
    end)
  end

  for _, name in ipairs({ "", "noSuchTool" }) do
    it('still answers -32601 for the string name "' .. name .. '"', function()
      send('{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"' .. name .. '"}}')

      assert.equals(1, #replies)
      assert.same({ code = -32601, message = "Tool not found: " .. name }, replies[1].error)
    end)
  end

  it("sends no answer to a notification", function()
    send('{"jsonrpc":"2.0","method":"tools/call"}')
    send('{"jsonrpc":"2.0","method":"tools/call","params":{"name":5}}')

    assert.equals(0, #replies)
  end)
end)
