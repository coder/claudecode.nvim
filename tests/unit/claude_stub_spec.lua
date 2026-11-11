-- Fails when a bare `claude` in busted resolves to anything but tests/bin/claude (see tests/helpers/busted_helper.lua).
describe("the stub claude on PATH", function()
  local root = require("pl.path").abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/unit/[^/]+$")
  local stub = root .. "/tests/bin/claude"

  ---@param command string
  ---@return string output The standard output and error of the command, run by the shell
  local function sh(command)
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    pipe:close()
    return output
  end

  it("is the first PATH entry", function()
    assert.equal(stub:match("^(.*)/[^/]+$"), (os.getenv("PATH") or ""):match("^[^:]*"))
  end)

  it("is what the shell finds and starts for a bare claude", function()
    -- Checked before the start: with another claude first on PATH, the start below would run the real CLI.
    assert.equal(stub .. "\n", sh("command -v claude"))

    assert.equal("claude-stub (claudecode.nvim tests)\n", sh("claude --version"))
  end)
end)
