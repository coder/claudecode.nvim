require("tests.busted_setup")
require("tests.mocks.vim")

local temp_dir = require("tests.helpers.temp_dir")

---Load a copy of init.lua from <dir>/lua/claudecode/init.lua, so it reads <dir>/VERSION.
---@param dir string
---@param version_text string|nil Contents of <dir>/VERSION, or nil for no file
local function load_copy(dir, version_text)
  os.execute("mkdir -p " .. temp_dir.quote(dir .. "/lua/claudecode"))
  local src = assert(io.open("lua/claudecode/init.lua", "r"))
  local dst = assert(io.open(dir .. "/lua/claudecode/init.lua", "w"))
  dst:write(src:read("*a"))
  src:close()
  dst:close()
  if version_text then
    local file = assert(io.open(dir .. "/VERSION", "w"))
    file:write(version_text)
    file:close()
  end
  return assert(loadfile(dir .. "/lua/claudecode/init.lua"))()
end

describe("claudecode.version", function()
  local dir

  before_each(function()
    dir = temp_dir.new()
  end)

  after_each(function()
    temp_dir.remove(dir)
    dir = nil
  end)

  it("matches the VERSION file that release-please bumps", function()
    package.loaded["claudecode"] = nil
    local claudecode = require("claudecode")
    local file = assert(io.open("VERSION", "r"), "run the tests from the repository root")
    local expected = file:read("*l")
    file:close()
    assert.are.equal(expected, claudecode.version:string())
  end)

  it("reads a prerelease from VERSION", function()
    local version = load_copy(dir, "1.12.3-rc.1\n").version
    assert.are.same({ 1, 12, 3, "rc.1" }, { version.major, version.minor, version.patch, version.prerelease })
    assert.are.equal("1.12.3-rc.1", version:string())
  end)

  it("reports 0.0.0-unknown without a VERSION file", function()
    assert.are.equal("0.0.0-unknown", load_copy(dir, nil).version:string())
  end)
end)
