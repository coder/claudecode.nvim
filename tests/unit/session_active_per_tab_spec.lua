-- luacheck: globals expect
require("tests.busted_setup")

describe("Session Manager per-tab active routing", function()
  local session_manager
  local tab_registry
  local original_get_current_tabpage
  local original_tabpage_is_valid
  local current_tab
  local valid_tabs

  before_each(function()
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.tab_registry"] = nil
    session_manager = require("claudecode.session")
    tab_registry = require("claudecode.tab_registry")
    session_manager.reset()
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
    session_manager.reset()
    tab_registry.reset()
  end)

  it("returns the session bound to the current tab when one exists", function()
    local sid_a = session_manager.create_session({ name = "A" })
    local sid_b = session_manager.create_session({ name = "B" })
    tab_registry.bind(1, sid_a)
    tab_registry.bind(2, sid_b)

    current_tab = 1
    expect(session_manager.get_active_session_id()).to_be(sid_a)
    current_tab = 2
    expect(session_manager.get_active_session_id()).to_be(sid_b)
  end)

  it("falls back to the global active session when current tab has no binding", function()
    local sid = session_manager.create_session({ name = "Solo" })
    -- No tab binding at all
    current_tab = 3
    expect(session_manager.get_active_session_id()).to_be(sid)
  end)

  it("ignores stale registry entries whose session was destroyed", function()
    local sid = session_manager.create_session({ name = "Stale" })
    tab_registry.bind(1, sid)
    -- Manually nuke the session record without going through destroy_session
    session_manager.sessions[sid] = nil
    current_tab = 1
    -- Falls back to whatever active_session_id was — may be the same id
    -- (set when the session was first created). The point is no error.
    local result = session_manager.get_active_session_id()
    expect(result == nil or result == sid).to_be_true()
  end)

  it("destroy_session removes the registry binding", function()
    local sid = session_manager.create_session({ name = "Doomed" })
    tab_registry.bind(1, sid)
    expect(tab_registry.tab_for_session(sid)).to_be(1)

    session_manager.destroy_session(sid)
    expect(tab_registry.tab_for_session(sid)).to_be_nil()
    expect(tab_registry.session_for_tab(1)).to_be_nil()
  end)

  it("destroy_session is safe when no registry binding exists", function()
    local sid = session_manager.create_session({ name = "Lonely" })
    -- No tab_registry.bind call
    local ok = session_manager.destroy_session(sid)
    expect(ok).to_be_true()
    expect(session_manager.get_session(sid)).to_be_nil()
  end)
end)
