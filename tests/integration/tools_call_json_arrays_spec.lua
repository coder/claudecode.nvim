-- Real-Neovim check that a tools/call tells a JSON array from a JSON object in `arguments`. vim.json.decode gives both
-- a Lua table, and gives the empty object {} the empty-dict mark and the empty array [] none. busted's mock vim keeps
-- no such mark, so only real Neovim shows that [] is refused and {} is not. Each answer is the text that the server
-- sends over the socket.
-- Under busted's mock vim it is pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("tools/call with a JSON array as arguments", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("tools/call with a JSON array as arguments", function()
  local server = require("claudecode.server.init")
  local tcp = require("claudecode.server.tcp")
  local islist = vim.islist or vim.tbl_islist
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

  local function reply_to(tool, arguments)
    wire = {}
    server._handle_message(
      { id = "array_spec" },
      '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"' .. tool .. '"' .. arguments .. "}}"
    )
    assert.equals(1, #wire)
    assert.is_nil(wire[1]:find("%.lua:%d"), "a Lua position reached the client: " .. wire[1])
    return wire[1]
  end

  it("decodes [] and {} to tables that a list test tells apart", function()
    assert.is_true(islist(vim.json.decode("[]")))
    assert.is_false(islist(vim.json.decode("{}")))
    assert.is_true(islist(vim.json.decode("[1]")))
    assert.is_false(islist(vim.json.decode('{"a":1}')))
  end)

  for _, tool in ipairs({ "getOpenEditors", "close_tab" }) do
    for _, arguments in ipairs({ "[]", "[1]", '[{"a":1}]' }) do
      it("answers -32602 for " .. arguments .. " as the arguments of " .. tool, function()
        local reply = vim.json.decode(reply_to(tool, ',"arguments":' .. arguments))

        assert.is_nil(reply.result)
        assert.same({
          code = -32602,
          message = "Invalid params",
          data = "Missing or invalid parameter: arguments (an object is required)",
        }, reply.error)
      end)
    end

    it("answers {} as the arguments of " .. tool .. " as it answers an absent arguments", function()
      assert.equals(reply_to(tool, ""), reply_to(tool, ',"arguments":{}'))
    end)
  end
end)
