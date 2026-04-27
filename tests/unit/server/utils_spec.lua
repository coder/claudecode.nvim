require("tests.busted_setup")

local utils = require("claudecode.server.utils")

describe("server.utils.apply_mask", function()
  it("XORs with a 4-byte mask and cycles", function()
    local data = "Hello"
    local mask = string.char(1, 2, 3, 4)

    local masked = utils.apply_mask(data, mask)

    expect(masked).to_be("Igohn")
    expect(utils.apply_mask(masked, mask)).to_be(data)
  end)

  it("handles empty payloads", function()
    expect(utils.apply_mask("", string.char(1, 2, 3, 4))).to_be("")
  end)

  it("handles 0x00 and 0xFF bytes", function()
    local data = string.char(0, 255, 1, 128)
    local mask = string.char(255, 0, 255, 0)

    local masked = utils.apply_mask(data, mask)
    expect(masked).to_be(string.char(255, 255, 254, 128))
    expect(utils.apply_mask(masked, mask)).to_be(data)
  end)

  it("errors on invalid mask length", function()
    local ok, err = pcall(utils.apply_mask, "hi", "a")

    expect(ok).to_be_false()
    assert_contains(tostring(err), "Expected mask to be 4 bytes")
  end)
end)
