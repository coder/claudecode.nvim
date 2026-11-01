--- tests/helpers/test_order.lua must report every test that a spec registers inside a pairs() loop, fail the run, and
--- still let the rest of the spec register and run. The spec below runs busted on a fixture spec, the way a user does.
require("tests.busted_setup")

-- Each line marked "flagged" registers inside a pairs() loop: directly, through a coroutine, or through a function.
local FIXTURE = {
  "local function register(name)",
  '  it("helper " .. name, function() end)',
  "end",
  'describe("block", function()',
  "  for name in pairs({ a = 1, b = 2 }) do",
  '    it("first loop " .. name, function() end) -- flagged',
  "  end",
  "  for name in pairs({ c = 1 }) do",
  '    it("second loop " .. name, function() end) -- flagged',
  "  end",
  '  it("after the loops", function() end)',
  '  for _, name in ipairs({ "x" }) do',
  '    it("ipairs " .. name, function() end)',
  "  end",
  "  for name in pairs({ d = 1 }) do",
  '    assert(coroutine.resume(coroutine.create(function() it("coroutine " .. name, function() end) end))) -- flagged',
  "  end",
  "  for name in pairs({ e = 1 }) do",
  '    coroutine.wrap(function() it("wrap " .. name, function() end) end)() -- flagged',
  "  end",
  "  for name in pairs({ f = 1 }) do",
  "    register(name) -- flagged",
  "  end",
  "end)",
}
local TESTS = 8

describe("the test order helper", function()
  local root = assert(io.popen("pwd")):read("*l")
  local dir, fixture

  setup(function()
    dir = os.tmpname()
    os.remove(dir)
    local made = os.execute("mkdir " .. dir)
    assert(made == 0 or made == true, "cannot create " .. dir)
    fixture = dir .. "/fixture_spec.lua"
    local file = assert(io.open(fixture, "w"))
    file:write(table.concat(FIXTURE, "\n"), "\n")
    file:close()
  end)

  teardown(function()
    os.execute("rm -rf " .. dir)
  end)

  ---@param command string The shell command that runs busted with TAP output
  ---@return integer[] flagged The fixture lines the helper reports, in order
  ---@return integer passed The number of fixture tests that ran and passed
  ---@return string status The exit status of busted
  local function run(command)
    local pipe = assert(io.popen(command .. " 2>&1; echo status=$?"))
    local output = pipe:read("*a")
    pipe:close()
    local flagged, passed = {}, 0
    for line in output:gmatch("fixture_spec%.lua:(%d+) registers ") do
      table.insert(flagged, tonumber(line))
    end
    for _ in output:gmatch("\nok %d+ %- block ") do
      passed = passed + 1
    end
    return flagged, passed, output:match("status=(%d+)")
  end

  local expected = {}
  for number, line in ipairs(FIXTURE) do
    if line:find("%-%- flagged$") then
      table.insert(expected, number)
    end
  end

  it("reports each pairs() loop once, runs every test, and fails the run for a spec given by absolute path", function()
    local flagged, passed, status = run(".luarocks/bin/busted -o TAP " .. fixture)

    table.sort(flagged)
    assert.same(expected, flagged)
    assert.equals(TESTS, passed)
    assert.are_not.equal("0", status)
  end)

  it("checks a spec when busted starts in another directory with --helper", function()
    local flagged = run(
      string.format(
        "cd %s && %s/.luarocks/bin/busted --helper=%s/tests/helpers/test_order.lua -o TAP %s",
        dir,
        root,
        root,
        fixture
      )
    )

    table.sort(flagged)
    assert.same(expected, flagged)
  end)
end)
