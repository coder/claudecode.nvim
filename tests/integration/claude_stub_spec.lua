-- Fails when a bare `claude` in the integration runner resolves to anything but tests/bin/claude (see
-- tests/minimal_init.lua).
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the stub claude on PATH", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("the stub claude on PATH", function()
  local stub = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h") .. "/bin/claude"

  it("is the first PATH entry", function()
    assert.equal(vim.fn.fnamemodify(stub, ":h"), vim.env.PATH:match("^[^:]*"))
  end)

  it("is what Neovim finds and starts for a bare claude", function()
    assert.equal(1, vim.fn.executable("claude"))
    -- Checked before the start: with another claude first on PATH, the start below would run the real CLI.
    assert.equal(vim.fn.resolve(stub), vim.fn.resolve(vim.fn.exepath("claude")))

    local output = vim.fn.system({ "claude", "--version" })

    assert.equal(0, vim.v.shell_error)
    assert.equal("claude-stub (claudecode.nvim tests)\n", output)
  end)
end)
