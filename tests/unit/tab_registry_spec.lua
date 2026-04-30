-- luacheck: globals expect
require("tests.busted_setup")

describe("tab_registry", function()
  local tab_registry
  local original_get_current_tabpage
  local original_tabpage_is_valid
  local current_tab
  local valid_tabs

  before_each(function()
    package.loaded["claudecode.tab_registry"] = nil
    tab_registry = require("claudecode.tab_registry")
    tab_registry.reset()

    current_tab = 1
    valid_tabs = { [1] = true, [2] = true, [3] = true }

    original_get_current_tabpage = vim.api.nvim_get_current_tabpage
    original_tabpage_is_valid = vim.api.nvim_tabpage_is_valid

    vim.api.nvim_get_current_tabpage = function()
      return current_tab
    end
    vim.api.nvim_tabpage_is_valid = function(tab)
      return valid_tabs[tab] == true
    end
  end)

  after_each(function()
    vim.api.nvim_get_current_tabpage = original_get_current_tabpage
    vim.api.nvim_tabpage_is_valid = original_tabpage_is_valid
    tab_registry.reset()
  end)

  it("binds and looks up by tab and by session", function()
    tab_registry.bind(1, "session_a")
    expect(tab_registry.session_for_tab(1)).to_be("session_a")
    expect(tab_registry.tab_for_session("session_a")).to_be(1)
  end)

  it("returns nil for unbound tab or session", function()
    expect(tab_registry.session_for_tab(99)).to_be_nil()
    expect(tab_registry.tab_for_session("ghost")).to_be_nil()
  end)

  it("a tab can own multiple sessions; binding does not evict siblings", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(1, "session_b")
    -- Both sessions are still owned by tab 1.
    expect(tab_registry.tab_for_session("session_a")).to_be(1)
    expect(tab_registry.tab_for_session("session_b")).to_be(1)
    -- The most recently bound session is the active one for the tab.
    expect(tab_registry.session_for_tab(1)).to_be("session_b")
    local owned = tab_registry.sessions_for_tab(1)
    table.sort(owned)
    assert.are.same({ "session_a", "session_b" }, owned)
  end)

  it("rebinding a session to a different tab transfers ownership", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(2, "session_a")
    expect(tab_registry.tab_for_session("session_a")).to_be(2)
    expect(tab_registry.session_for_tab(1)).to_be_nil()
    expect(tab_registry.session_for_tab(2)).to_be("session_a")
  end)

  it("set_active updates the per-tab active pointer without changing ownership", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(1, "session_b")
    expect(tab_registry.session_for_tab(1)).to_be("session_b")
    tab_registry.set_active("session_a")
    expect(tab_registry.session_for_tab(1)).to_be("session_a")
    -- Ownership unchanged.
    expect(tab_registry.tab_for_session("session_a")).to_be(1)
    expect(tab_registry.tab_for_session("session_b")).to_be(1)
  end)

  it("unbind_tab clears every session owned by that tab", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(1, "session_b")
    tab_registry.bind(2, "session_c")
    tab_registry.unbind_tab(1)
    expect(tab_registry.session_for_tab(1)).to_be_nil()
    expect(tab_registry.tab_for_session("session_a")).to_be_nil()
    expect(tab_registry.tab_for_session("session_b")).to_be_nil()
    expect(tab_registry.tab_for_session("session_c")).to_be(2)
  end)

  it("unbind_session promotes a sibling to active when removing the active session", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(1, "session_b")
    expect(tab_registry.session_for_tab(1)).to_be("session_b")
    tab_registry.unbind_session("session_b")
    expect(tab_registry.session_for_tab(1)).to_be("session_a")
    expect(tab_registry.tab_for_session("session_b")).to_be_nil()
  end)

  it("unbind_session leaves siblings untouched", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(1, "session_b")
    tab_registry.unbind_session("session_a")
    expect(tab_registry.tab_for_session("session_a")).to_be_nil()
    expect(tab_registry.tab_for_session("session_b")).to_be(1)
    expect(tab_registry.session_for_tab(1)).to_be("session_b")
  end)

  it("current_session resolves via current tabpage", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(2, "session_b")
    current_tab = 2
    expect(tab_registry.current_session()).to_be("session_b")
    current_tab = 1
    expect(tab_registry.current_session()).to_be("session_a")
  end)

  it("current_session is nil when current tab is unbound", function()
    tab_registry.bind(1, "session_a")
    current_tab = 3
    expect(tab_registry.current_session()).to_be_nil()
  end)

  it("prune_invalid_tabs removes bindings for closed tabs and returns orphans", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(2, "session_b")
    tab_registry.bind(2, "session_b2")
    tab_registry.bind(3, "session_c")

    valid_tabs[2] = nil

    local orphans = tab_registry.prune_invalid_tabs()
    table.sort(orphans)
    assert.are.same({ "session_b", "session_b2" }, orphans)
    expect(tab_registry.session_for_tab(2)).to_be_nil()
    expect(tab_registry.tab_for_session("session_b")).to_be_nil()
    expect(tab_registry.tab_for_session("session_b2")).to_be_nil()
    expect(tab_registry.session_for_tab(1)).to_be("session_a")
    expect(tab_registry.session_for_tab(3)).to_be("session_c")
  end)

  it("snapshot returns per-tab sessions plus active", function()
    tab_registry.bind(1, "session_a")
    tab_registry.bind(1, "session_b")
    tab_registry.bind(2, "session_c")
    local snap = tab_registry.snapshot()
    assert.is_table(snap[1])
    expect(snap[1].active).to_be("session_b")
    table.sort(snap[1].sessions)
    assert.are.same({ "session_a", "session_b" }, snap[1].sessions)
    expect(snap[2].active).to_be("session_c")
    assert.are.same({ "session_c" }, snap[2].sessions)
  end)

  it("bind ignores nil arguments", function()
    tab_registry.bind(nil, "session_a")
    tab_registry.bind(1, nil)
    expect(tab_registry.session_for_tab(1)).to_be_nil()
    expect(tab_registry.tab_for_session("session_a")).to_be_nil()
  end)
end)
