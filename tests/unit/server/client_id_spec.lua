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

  -- A reload drops the module's locals, while the diff module still holds the old ids.
  it("never repeat after claudecode.server.client is reloaded", function()
    local seen = {}
    for _ = 1, 3 do
      package.loaded["claudecode.server.client"] = nil
      local reloaded = require("claudecode.server.client")
      for _ = 1, 2 do
        local id = reloaded.create_client(handle_at("0x5555deadbeef")).id
        assert.is_nil(seen[id], "id " .. id .. " came back after a reload")
        seen[id] = true
      end
    end
  end)
end)
