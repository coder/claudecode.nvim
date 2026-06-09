require("tests.busted_setup")

describe("Diff/idle terminal split width resolution", function()
  local diff = require("claudecode.diff")

  local function resolve(when)
    return diff._resolve_split_width_percentage(when)
  end

  it("uses split_width_percentage for both states when diff width is unset", function()
    diff.setup({ terminal = { split_width_percentage = 0.5 } })
    assert.are.equal(0.5, resolve("idle"))
    assert.are.equal(0.5, resolve("diff"))
  end)

  it("shrinks to diff_split_width_percentage while a diff is active, idle unchanged", function()
    diff.setup({ terminal = { split_width_percentage = 0.5, diff_split_width_percentage = 0.3 } })
    assert.are.equal(0.5, resolve("idle"))
    assert.are.equal(0.3, resolve("diff"))
  end)

  it("falls back to the 0.30 default when no widths are configured", function()
    diff.setup({ terminal = {} })
    assert.are.equal(0.30, resolve("idle"))
    assert.are.equal(0.30, resolve("diff"))
  end)

  it("ignores an out-of-range diff width and falls back to the idle width", function()
    diff.setup({ terminal = { split_width_percentage = 0.5, diff_split_width_percentage = 2.0 } })
    assert.are.equal(0.5, resolve("diff"))
  end)

  it("ignores a non-number diff width and falls back to the idle width", function()
    diff.setup({ terminal = { split_width_percentage = 0.4, diff_split_width_percentage = "wide" } })
    assert.are.equal(0.4, resolve("diff"))
  end)

  it("allows a diff width wider than the idle width", function()
    diff.setup({ terminal = { split_width_percentage = 0.3, diff_split_width_percentage = 0.6 } })
    assert.are.equal(0.3, resolve("idle"))
    assert.are.equal(0.6, resolve("diff"))
  end)
end)
