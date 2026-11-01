--- scripts/check_test_order.sh, which `mise run check` runs, must flag every pairs() loop that registers tests and
--- nothing else. The spec lines below are strings, so the check does not read them as loops of this file.
require("tests.busted_setup")

describe("scripts/check_test_order.sh", function()
  local dir

  before_each(function()
    dir = os.tmpname()
    os.remove(dir)
    local made = os.execute("mkdir " .. dir)
    assert(made == 0 or made == true, "cannot create " .. dir)
  end)

  after_each(function()
    os.execute("rm -rf " .. dir)
  end)

  ---@param lines string[] The spec file, one line per entry
  ---@return string[] flagged The line numbers the check reports
  ---@return string status The script's exit status
  local function check(lines)
    local file = assert(io.open(dir .. "/case_spec.lua", "w"))
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
    local pipe = assert(io.popen("scripts/check_test_order.sh " .. dir .. " 2>&1; echo status=$?"))
    local output = pipe:read("*a")
    pipe:close()
    local flagged = {}
    for line_number in output:gmatch("case_spec%.lua:(%d+):") do
      table.insert(flagged, line_number)
    end
    return flagged, output:match("status=(%d+)")
  end

  it("flags a pairs() loop at the top level of a spec", function()
    local flagged, status = check({
      "for name in pairs({ a = 1, b = 2 }) do",
      '  it("case " .. name, function() end)',
      "end",
    })

    assert.same({ "1" }, flagged)
    assert.are_not.equal("0", status)
  end)

  it("flags a pairs() loop whose body registers through describe or pending", function()
    local flagged = check({
      'describe("cases", function()',
      "  for name in pairs({ a = 1 }) do",
      '    describe("nested " .. name, function()',
      '      it("deep", function() end)',
      "    end)",
      "  end",
      "  for name in pairs({ a = 1 }) do",
      '    pending("later " .. name)',
      "  end",
      "end)",
    })

    assert.same({ "2", "7" }, flagged)
  end)

  it("passes ipairs loops, one-line loops, and loops without tests, even when end has a comment", function()
    local flagged, status = check({
      'describe("cases", function()',
      '  for _, case in ipairs({ { "a" } }) do',
      '    it("case " .. case[1], function() end)',
      "  end",
      "  for k, v in pairs({ a = 1 }) do print(k, v) end",
      "  for k in pairs({ a = 1 }) do",
      "    print(k)",
      "  end -- the order of these prints does not matter",
      '  it("after the loops", function() end)',
      "end)",
    })

    assert.same({}, flagged)
    assert.equals("0", status)
  end)
end)
