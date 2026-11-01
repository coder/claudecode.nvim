--- tests/helpers/temp_dir.lua must work under any TMPDIR, including one with a space or a quote in its path.
require("tests.busted_setup")

---@param text string
---@return string quoted text as one POSIX shell word
local function quote(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

describe("temp_dir", function()
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  local parent

  setup(function()
    parent = os.tmpname()
    os.remove(parent)
    parent = parent .. " it's"
    assert(os.execute("mkdir " .. quote(parent)))
  end)

  teardown(function()
    os.execute("rm -rf " .. quote(parent))
  end)

  it("makes and removes a folder under a TMPDIR with a space and a quote", function()
    local spec = parent .. "/fixture_spec.lua"
    local file = assert(io.open(spec, "w"))
    file:write(table.concat({
      'local temp_dir = require("tests.helpers.temp_dir")',
      'it("works", function()',
      "  local dir = temp_dir.new()",
      '  assert(dir:sub(1, #os.getenv("TMPDIR")) == os.getenv("TMPDIR"), dir)',
      '  assert(io.open(dir .. "/file.txt", "w")):close()',
      "  temp_dir.remove(dir)",
      '  assert(not os.rename(dir, dir), dir .. " is still there")',
      "end)",
    }, "\n"))
    file:close()

    local pipe = assert(
      io.popen(
        string.format(
          "cd %s && TMPDIR=%s %s %s 2>&1; echo status=$?",
          quote(root),
          quote(parent),
          quote(root .. "/.luarocks/bin/busted"),
          quote(spec)
        )
      )
    )
    local output = pipe:read("*a")
    pipe:close()

    assert.is_truthy(output:find("status=0", 1, true), output)
  end)
end)
