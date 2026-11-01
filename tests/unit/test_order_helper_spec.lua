--- tests/helpers/test_order.lua must report every test that a spec registers inside a pairs() loop, fail that test, and
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

---@param text string
---@return string quoted text as one POSIX shell word
local function quote(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

describe("the test order helper", function()
  -- The repo root, from this file's path, so the spec runs from any directory.
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  -- Busted reads .busted, which loads the helper, from the directory it starts in.
  local busted = "cd " .. quote(root) .. " && " .. quote(root .. "/.luarocks/bin/busted")
  -- Two copies whose paths end alike for longer than Lua's 60-byte short_src, in a dir with a space and a quote.
  local long_tail = string.rep("x", 70) .. "/fixture_spec.lua"
  local dir, fixture, twin

  setup(function()
    dir = os.tmpname()
    os.remove(dir)
    dir = dir .. " it's"
    for _, path in ipairs({
      dir,
      dir .. "/a",
      dir .. "/b",
      dir .. "/a/" .. string.rep("x", 70),
      dir .. "/b/" .. string.rep("x", 70),
    }) do
      local made = os.execute("mkdir " .. quote(path))
      assert(made == 0 or made == true, "cannot create " .. path)
    end
    fixture, twin = dir .. "/a/" .. long_tail, dir .. "/b/" .. long_tail
    for _, path in ipairs({ fixture, twin }) do
      local file = assert(io.open(path, "w"))
      file:write(table.concat(FIXTURE, "\n"), "\n")
      file:close()
    end
  end)

  teardown(function()
    os.execute("rm -rf " .. quote(dir))
  end)

  ---@param command string The shell command that runs busted with TAP output
  ---@param file string|nil The file whose reported lines to collect (default the fixture spec)
  ---@return integer[] flagged The lines of `file` the helper reports, in order
  ---@return integer passed The number of fixture tests that ran and passed
  ---@return integer failed The number of fixture tests that failed
  ---@return string status The exit status of busted
  local function run(command, file)
    local pipe = assert(io.popen(command .. " 2>&1; echo status=$?"))
    -- A newline first, so the first TAP line matches the patterns below too.
    local output = "\n" .. pipe:read("*a")
    pipe:close()
    local flagged, passed, failed = {}, 0, 0
    for line in output:gmatch("/" .. (file or "fixture_spec%.lua") .. ":(%d+): registers ") do
      table.insert(flagged, tonumber(line))
    end
    for _ in output:gmatch("\nok %d+ %- block ") do
      passed = passed + 1
    end
    for _ in output:gmatch("\nnot ok %d+ %- block ") do
      failed = failed + 1
    end
    return flagged, passed, failed, output:match("status=(%d+)")
  end

  local expected = {}
  for number, line in ipairs(FIXTURE) do
    if line:find("%-%- flagged$") then
      table.insert(expected, number)
    end
  end

  it(
    "reports each pairs() loop once in a test that fails, and runs every test, for a spec given by absolute path",
    function()
      local flagged, passed, failed, status = run(busted .. " -o TAP " .. quote(fixture))

      table.sort(flagged)
      assert.same(expected, flagged)
      -- TAP says "not ok" for the first test of each loop. The second test of the first loop passes.
      assert.same({ TESTS - #expected, #expected }, { passed, failed })
      assert.are_not.equal("0", status)
    end
  )

  it("reports the same loop line in two spec files whose paths end alike", function()
    local flagged = run(busted .. " -o TAP " .. quote(fixture) .. " " .. quote(twin))

    local both = {}
    for _, line in ipairs(expected) do
      table.insert(both, line)
      table.insert(both, line)
    end
    table.sort(flagged)
    assert.same(both, flagged)
  end)

  it("checks a spec when busted starts in another directory with --helper", function()
    local flagged = run(
      string.format(
        "cd %s && %s -o TAP --helper=%s %s",
        quote(dir),
        quote(root .. "/.luarocks/bin/busted"),
        quote(root .. "/tests/helpers/test_order.lua"),
        quote(fixture)
      )
    )

    table.sort(flagged)
    assert.same(expected, flagged)
  end)

  it("checks a module in the helper's tests directory that a spec calls to register tests", function()
    -- A copy of the helper, so that the module can be in its tests directory without writing into the repo.
    local tests = dir .. "/tests"
    for _, path in ipairs({ tests, tests .. "/helpers" }) do
      local made = os.execute("mkdir " .. quote(path))
      assert(made == 0 or made == true, "cannot create " .. path)
    end
    local helper = tests .. "/helpers/test_order.lua"
    local files = {
      [helper] = assert(io.open(root .. "/tests/helpers/test_order.lua")):read("*a"),
      [tests .. "/helpers/register_in_pairs.lua"] = table.concat({
        "return function(it)",
        "  for name in pairs({ g = 1 }) do",
        '    it("module " .. name, function() end) -- flagged',
        "  end",
        "end",
      }, "\n"),
      [tests .. "/module_spec.lua"] = table.concat({
        'local path = debug.getinfo(1, "S").source:sub(2):gsub("module_spec%.lua$", "helpers/register_in_pairs.lua")',
        'describe("block", function()',
        "  dofile(path)(it)",
        "end)",
      }, "\n"),
    }
    for _, path in ipairs({ helper, tests .. "/helpers/register_in_pairs.lua", tests .. "/module_spec.lua" }) do
      local file = assert(io.open(path, "w"))
      file:write(files[path], "\n")
      file:close()
    end

    local flagged, passed, failed = run(
      string.format(
        "cd %s && %s -o TAP --helper=%s %s",
        quote(dir),
        quote(root .. "/.luarocks/bin/busted"),
        quote(helper),
        quote(tests .. "/module_spec.lua")
      ),
      "register_in_pairs%.lua"
    )

    assert.same({ 3 }, flagged)
    assert.same({ 0, 1 }, { passed, failed })
  end)
end)
