-- luacheck: globals expect
require("tests.busted_setup")

describe("terminal.list_sessions_for_current_tab", function()
  local terminal
  local session_manager
  local tab_registry
  local original_get_current_tabpage
  local current_tab

  before_each(function()
    -- Reset all the modules we depend on so state from earlier specs doesn't
    -- leak into ours.
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.tab_registry"] = nil
    package.loaded["claudecode.terminal.osc_handler"] = nil

    session_manager = require("claudecode.session")
    tab_registry = require("claudecode.tab_registry")
    terminal = require("claudecode.terminal")
    session_manager.reset()
    tab_registry.reset()

    current_tab = 1
    original_get_current_tabpage = vim.api.nvim_get_current_tabpage
    vim.api.nvim_get_current_tabpage = function()
      return current_tab
    end
  end)

  after_each(function()
    vim.api.nvim_get_current_tabpage = original_get_current_tabpage
    session_manager.reset()
    tab_registry.reset()
  end)

  it("returns every session bound to the current tab", function()
    local sid_a1 = session_manager.create_session({ name = "A1" })
    local sid_a2 = session_manager.create_session({ name = "A2" })
    local sid_b1 = session_manager.create_session({ name = "B1" })

    tab_registry.bind(1, sid_a1)
    tab_registry.bind(1, sid_a2)
    tab_registry.bind(2, sid_b1)

    current_tab = 1
    local listed = terminal.list_sessions_for_current_tab()
    local names = {}
    for _, s in ipairs(listed) do
      table.insert(names, s.name)
    end
    table.sort(names)
    assert.are.same({ "A1", "A2" }, names)
  end)

  it("excludes unbound sessions to prevent cross-tab leakage", function()
    session_manager.create_session({ name = "Unbound" })
    -- No tab_registry.bind call: this session has no owner.
    current_tab = 7
    expect(#terminal.list_sessions_for_current_tab()).to_be(0)
  end)

  it("excludes sessions belonging to other tabs", function()
    local sid_other = session_manager.create_session({ name = "Other" })
    tab_registry.bind(2, sid_other)
    current_tab = 1
    expect(#terminal.list_sessions_for_current_tab()).to_be(0)
  end)

  it("returns empty array when there are no sessions at all", function()
    current_tab = 1
    local listed = terminal.list_sessions_for_current_tab()
    assert.is_table(listed)
    expect(#listed).to_be(0)
  end)
end)
