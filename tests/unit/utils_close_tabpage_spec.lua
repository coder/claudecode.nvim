require("tests.busted_setup")

describe("claudecode.utils.close_tabpage_without_entering", function()
  local utils = require("claudecode.utils")
  local real_cmd
  local real_set_current_tabpage
  local commands
  local entered

  before_each(function()
    real_cmd = vim.cmd
    real_set_current_tabpage = vim.api.nvim_set_current_tabpage
    commands = {}
    entered = {}
    vim.cmd = function(command)
      table.insert(commands, command)
    end
    vim.api.nvim_set_current_tabpage = function(tab)
      table.insert(entered, tab)
    end
  end)

  after_each(function()
    vim.cmd = real_cmd
    vim.api.nvim_set_current_tabpage = real_set_current_tabpage
  end)

  it("closes the tab page by its number and never makes it the current tab page", function()
    utils.close_tabpage_without_entering(2)

    assert.same({ "tabclose 2" }, commands)
    assert.same({}, entered)
  end)

  it("does not raise when Neovim refuses to close the tab page", function()
    vim.cmd = function()
      error("E784: Cannot close last tab page", 0)
    end

    assert.has_no.errors(function()
      utils.close_tabpage_without_entering(2)
    end)
  end)
end)
