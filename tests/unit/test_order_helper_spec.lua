--- tests/helpers/test_order.lua, which `.busted` loads for every run, must refuse a test registered inside a pairs()
--- loop and accept every other registration.
require("tests.busted_setup")

describe("the test order helper", function()
  local register_it

  before_each(function()
    local subscribers = {}
    local busted = {
      subscribe = function(channel, fn)
        subscribers[channel[2]] = fn
      end,
    }
    assert.is_true(dofile("tests/helpers/test_order.lua")(busted))
    register_it = subscribers.it
  end)

  it("refuses a registration inside a pairs() loop and names the loop's file", function()
    for _ in pairs({ a = 1 }) do
      local ok, err = pcall(register_it, "case")
      assert.is_false(ok)
      assert.matches('test_order_helper_spec%.lua:%d+ registers "case" inside a pairs%(%) loop', err)
    end
  end)

  it("refuses a registration from a function that a pairs() loop calls", function()
    local function register()
      return pcall(register_it, "case")
    end
    for _ in pairs({ a = 1 }) do
      assert.is_false(register())
    end
  end)

  it("ignores a pairs() loop in code outside this repository's tests dir", function()
    -- Busted's own event loop iterates with pairs(). A checkout below another dir named tests must not count it.
    local outside = assert(
      load(
        "local register = ... for _ in pairs({ a = 1 }) do local value, continue = register('case') return value, continue end",
        "@/tmp/tests/claudecode.nvim/.luarocks/share/lua/5.1/mediator.lua"
      )
    )
    assert.same({ nil, true }, { outside(register_it) })
  end)

  it("accepts a registration inside an ipairs() loop, and after a pairs() loop", function()
    for _ in ipairs({ 1 }) do
      assert.same({ nil, true }, { register_it("case") })
    end
    for _ in pairs({ a = 1 }) do
    end
    assert.same({ nil, true }, { register_it("case") })
  end)
end)
