--- A diff the user accepted stays tied to the id of the client that opened it, even after that
--- client disconnects. A later connection must never get that id back, or it passes as the owner
--- and can tear the diff down (issue #342).
require("tests.busted_setup")
local client_manager = require("claudecode.server.client")

describe("WebSocket client ids", function()
  -- libuv can hand a new TCP handle the address of a collected one, so two handles can print alike.
  local function handle_at(address)
    return setmetatable({}, {
      __tostring = function()
        return "userdata: " .. address
      end,
    })
  end

  it("differ for two connections whose handles share an address", function()
    local first = client_manager.create_client(handle_at("0x5555deadbeef"))
    local second = client_manager.create_client(handle_at("0x5555deadbeef"))

    assert.are_not.equal(first.id, second.id)
  end)
end)
