require("tests.busted_setup")
require("tests.mocks.vim")

describe("none terminal provider", function()
  local terminal

  local termopen_calls
  local jobstart_calls

  before_each(function()
    -- Prepare vim.fn helpers used by terminal module
    vim.fn = vim.fn or {}
    vim.fn.getcwd = function()
      return "/mock/cwd"
    end
    vim.fn.expand = function(val)
      return val
    end

    -- Spy-able termopen/jobstart that count invocations
    termopen_calls = 0
    jobstart_calls = 0
    vim.fn.termopen = function(...)
      termopen_calls = termopen_calls + 1
      return 1
    end
    vim.fn.jobstart = function(...)
      jobstart_calls = jobstart_calls + 1
      return 1
    end

    -- Minimal logger + server mocks
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
      info = function() end,
      setup = function() end,
    }
    package.loaded["claudecode.server.init"] = { state = { port = 12345 } }

    -- Ensure fresh terminal module load
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.terminal.none"] = nil
    package.loaded["claudecode.terminal.native"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil

    terminal = require("claudecode.terminal")
    terminal.setup({ provider = "none" }, nil, {})
  end)

  it("does not invoke any terminal APIs", function()
    -- Exercise all public actions
    terminal.open({}, "--help")
    terminal.simple_toggle({}, "--resume")
    terminal.focus_toggle({}, "--continue")
    terminal.ensure_visible({}, nil)
    terminal.toggle_open_no_focus({}, nil)
    terminal.close()

    -- Assert no terminal processes/windows were spawned
    assert.are.equal(0, termopen_calls)
    assert.are.equal(0, jobstart_calls)
  end)

  it("returns nil for active buffer", function()
    local bufnr = terminal.get_active_terminal_bufnr()
    assert.is_nil(bufnr)
  end)
end)
