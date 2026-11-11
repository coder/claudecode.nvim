--- A malformed tools/call gets -32602 "Invalid params" and plain text in `data`, never a Lua error with a file path.
--- Malformed means params that is not an object, a name that is not a string, or arguments that is not an object. An
--- empty or unknown string name is a well-formed request for a tool that does not exist (-32601), a call without
--- arguments reaches its tool with an empty table, and a notification gets no answer. The mock vim cannot tell {} from
--- [], so the answer for "params": {} is in tests/integration/tools_call_json_arrays_spec.lua.
require("tests.busted_setup")

describe("the shape of a tools/call", function()
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

  local function tools_call(params_json)
    return '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":' .. params_json .. "}"
  end

  for _, case in ipairs({
    { label = "a number as params", params = "5" },
    { label = "a boolean as params", params = "true" },
    { label = "false as params", params = "false" },
    { label = "a string as params", params = '"x"' },
    { label = "a list as params", params = "[1]" },
    { label = "an empty list as params", params = "[]" },
  }) do
    it("answers -32602 naming params for " .. case.label, function()
      send(tools_call(case.params))

      assert.equals(1, #replies)
      assert.equals(6, replies[1].id)
      assert.is_nil(replies[1].result)
      assert.same({
        code = -32602,
        message = "Invalid params",
        data = "Missing or invalid parameter: params (an object is required)",
      }, replies[1].error)
    end)
  end

  it("answers -32602 naming params for a request without params", function()
    send('{"jsonrpc":"2.0","id":6,"method":"tools/call"}')

    assert.equals(1, #replies)
    assert.equals(6, replies[1].id)
    assert.is_nil(replies[1].result)
    assert.same({
      code = -32602,
      message = "Invalid params",
      data = "Missing or invalid parameter: params (an object is required)",
    }, replies[1].error)
  end)

  for _, case in ipairs({
    { label = "a number", arguments = "5" },
    { label = "a boolean", arguments = "true" },
    { label = "a string", arguments = '"x"' },
    { label = "a list", arguments = "[1]" },
    { label = "an empty list", arguments = "[]" },
  }) do
    it("answers -32602 naming arguments for " .. case.label .. " as arguments", function()
      send(tools_call('{"name":"getOpenEditors","arguments":' .. case.arguments .. "}"))

      assert.equals(1, #replies)
      assert.is_nil(replies[1].result)
      assert.same({
        code = -32602,
        message = "Invalid params",
        data = "Missing or invalid parameter: arguments (an object is required)",
      }, replies[1].error)
    end)
  end

  for _, case in ipairs({
    { tool = "openFile", data = "Missing filePath parameter" },
    { tool = "checkDocumentDirty", data = "Missing filePath parameter" },
    { tool = "saveDocument", data = "Missing filePath parameter" },
    { tool = "close_tab", data = "Missing required parameter: tab_name" },
    { tool = "openDiff", data = "Missing required parameter: old_file_path" },
  }) do
    it("answers the missing-parameter error of " .. case.tool .. " when the call has no arguments", function()
      require("claudecode.tools.init").register_all()

      send(tools_call('{"name":"' .. case.tool .. '"}'))

      assert.equals(1, #replies)
      assert.is_nil(replies[1].result)
      assert.same({ code = -32602, message = "Invalid params", data = case.data }, replies[1].error)
    end)
  end

  it("sends no answer to a notification", function()
    send('{"jsonrpc":"2.0","method":"tools/call"}')
    send('{"jsonrpc":"2.0","method":"tools/call","params":{"name":5}}')
    send('{"jsonrpc":"2.0","method":"tools/call","params":5}')

    assert.equals(0, #replies)
  end)
end)
