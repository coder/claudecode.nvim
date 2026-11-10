--- server/mock.lua stands in for server/init.lua, so its broadcast must report delivery the same way: true only when a
--- client took the message. The @ mention queue keeps a mention that no client took.
require("tests.busted_setup")

describe("The mock server's broadcast", function()
  local mock

  before_each(function()
    package.loaded["claudecode.server.mock"] = nil
    mock = require("claudecode.server.mock")
    assert(mock.start({ port_range = { min = 10000, max = 10001 } }))
  end)

  after_each(function()
    if mock.state.server then
      mock.stop()
    end
  end)

  it("returns false when no client takes the message", function()
    assert.is_false(mock.broadcast("at_mentioned", { filePath = "a.lua" }))
  end)

  it("returns true when a client takes the message, and the client has it", function()
    local client = mock.add_client("client_a")

    assert.is_true(mock.broadcast("at_mentioned", { filePath = "a.lua" }))
    assert.equals(1, #client.messages)
    assert.equals("at_mentioned", client.messages[1].method)
  end)

  it("returns false again once the last client is gone", function()
    mock.add_client("client_a")
    mock.remove_client("client_a")

    assert.is_false(mock.broadcast("at_mentioned", { filePath = "a.lua" }))
  end)

  it("returns false when the server is stopped", function()
    mock.add_client("client_a")
    mock.stop()

    assert.is_false(mock.broadcast("at_mentioned", { filePath = "a.lua" }))
  end)
end)
