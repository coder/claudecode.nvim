if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("claudecode.utils.without_autocmds", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("claudecode.utils.without_autocmds", function()
  local utils = require("claudecode.utils")
  local fired
  local autocmd_id

  before_each(function()
    fired = 0
    autocmd_id = vim.api.nvim_create_autocmd("User", {
      pattern = "ClaudeCodeWithoutAutocmdsSpec",
      callback = function()
        fired = fired + 1
      end,
    })
  end)

  after_each(function()
    vim.api.nvim_del_autocmd(autocmd_id)
  end)

  local function fire()
    vim.api.nvim_exec_autocmds("User", { pattern = "ClaudeCodeWithoutAutocmdsSpec" })
  end

  it("runs no autocmd while the function runs, and runs them again afterwards", function()
    utils.without_autocmds(fire)
    assert.equal(0, fired)

    fire()
    assert.equal(1, fired)
  end)

  it("keeps autocmds blocked until the outermost call returns", function()
    utils.without_autocmds(function()
      utils.without_autocmds(fire)
      fire()
    end)
    assert.equal(0, fired)

    fire()
    assert.equal(1, fired)
  end)

  it("raises the error of the function and runs autocmds again", function()
    local ok, err = pcall(utils.without_autocmds, function()
      error("boom", 0)
    end)

    assert.is_false(ok)
    assert.is_true(tostring(err):find("boom", 1, true) ~= nil, tostring(err))
    fire()
    assert.equal(1, fired)
  end)

  it("fires no OptionSet event and leaves 'eventignore' alone", function()
    local option_events = 0
    local option_id = vim.api.nvim_create_autocmd("OptionSet", {
      callback = function()
        option_events = option_events + 1
      end,
    })
    local before = vim.o.eventignore

    utils.without_autocmds(function()
      vim.o.eventignore = before
    end)

    vim.api.nvim_del_autocmd(option_id)
    assert.equal(before, vim.o.eventignore)
    assert.equal(0, option_events)
  end)
end)
