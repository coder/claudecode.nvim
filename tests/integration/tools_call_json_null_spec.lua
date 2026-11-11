-- Real-Neovim check of a tools/call that carries a JSON null. vim.json.decode turns null into vim.NIL, a userdata, while
-- busted's mock vim decodes null to nil, so only real Neovim shows what reaches the server. Each answer is the text
-- that the server sends over the socket, decoded again with the real vim.json.decode.
-- Under busted's mock vim it is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("tools/call with a JSON null", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("tools/call with a JSON null", function()
  local server = require("claudecode.server.init")
  local tcp = require("claudecode.server.tcp")
  local original, wire

  before_each(function()
    require("claudecode.tools.init").register_all()
    server.register_handlers()
    original = { server = server.state.server, send_to_client = tcp.send_to_client }
    server.state.server = {}
    wire = {}
    tcp.send_to_client = function(_, _, json)
      table.insert(wire, json)
    end
  end)

  after_each(function()
    server.state.server = original.server
    tcp.send_to_client = original.send_to_client
  end)

  it("decodes null to a userdata, not to nil", function()
    assert.equals("userdata", type(vim.json.decode('{"params":null}').params))
  end)

  local function arguments_of(tool, key)
    return '{"name":"' .. tool .. '","arguments":{"' .. key .. '":null}}'
  end

  for _, case in ipairs({
    { label = "params", params = "null", data = "params (an object is required)" },
    { label = "name", params = '{"name":null}', data = "name (a string is required)" },
    {
      label = "arguments",
      params = '{"name":"getOpenEditors","arguments":null}',
      data = "arguments (an object is required)",
    },
  }) do
    it("answers -32602 with plain text for a null " .. case.label, function()
      server._handle_message(
        { id = "null_spec" },
        '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":' .. case.params .. "}"
      )

      assert.equals(1, #wire)
      assert.is_nil(wire[1]:find("%.lua:%d"), "a Lua position reached the client: " .. wire[1])
      local reply = vim.json.decode(wire[1])
      assert.equals(7, reply.id)
      assert.is_nil(reply.result)
      assert.same({
        code = -32602,
        message = "Invalid params",
        data = "Missing or invalid parameter: " .. case.data,
      }, reply.error)
    end)
  end

  for _, case in ipairs({
    { tool = "openFile", key = "filePath", data = "Missing filePath parameter" },
    { tool = "checkDocumentDirty", key = "filePath", data = "Missing filePath parameter" },
    { tool = "saveDocument", key = "filePath", data = "Missing filePath parameter" },
    { tool = "close_tab", key = "tab_name", data = "Missing required parameter: tab_name" },
    { tool = "getDiagnostics", key = "uri", data = "Invalid parameter: uri (a string is required)" },
    { tool = "openDiff", key = "tab_name", data = "Missing required parameter: tab_name" },
  }) do
    it("answers -32602 for a null " .. case.key .. " of " .. case.tool, function()
      local arguments = arguments_of(case.tool, case.key)
      if case.tool == "openDiff" then
        arguments =
          '{"name":"openDiff","arguments":{"old_file_path":"a","new_file_path":"a","new_file_contents":"b","tab_name":null}}'
      end
      server._handle_message(
        { id = "null_spec" },
        '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":' .. arguments .. "}"
      )

      assert.equals(1, #wire)
      assert.is_nil(wire[1]:find("%.lua:%d"), "a Lua position reached the client: " .. wire[1])
      local reply = vim.json.decode(wire[1])
      assert.is_nil(reply.result)
      assert.same({ code = -32602, message = "Invalid params", data = case.data }, reply.error)
    end)
  end
end)
