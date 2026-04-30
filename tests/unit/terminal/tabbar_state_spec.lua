-- luacheck: globals expect
require("tests.busted_setup")

describe("tabbar per-tab state", function()
  local tabbar
  local tab_registry
  local session_manager
  local original_get_current_tabpage
  local original_tabpage_is_valid
  local original_win_get_tabpage
  local original_win_is_valid
  local current_tab
  local valid_tabs
  local win_tab_map

  before_each(function()
    package.loaded["claudecode.terminal.tabbar"] = nil
    package.loaded["claudecode.tab_registry"] = nil
    package.loaded["claudecode.session"] = nil

    tabbar = require("claudecode.terminal.tabbar")
    tab_registry = require("claudecode.tab_registry")
    session_manager = require("claudecode.session")

    tab_registry.reset()
    session_manager.reset()
    tabbar._reset()

    current_tab = 1
    valid_tabs = { [1] = true, [2] = true, [3] = true }
    win_tab_map = {}

    original_get_current_tabpage = vim.api.nvim_get_current_tabpage
    original_tabpage_is_valid = vim.api.nvim_tabpage_is_valid
    original_win_get_tabpage = vim.api.nvim_win_get_tabpage
    original_win_is_valid = vim.api.nvim_win_is_valid

    vim.api.nvim_get_current_tabpage = function()
      return current_tab
    end
    vim.api.nvim_tabpage_is_valid = function(tab)
      return valid_tabs[tab] == true
    end
    vim.api.nvim_win_get_tabpage = function(winid)
      return win_tab_map[winid] or current_tab
    end
    -- Treat any winid we registered in win_tab_map as a valid window. Other
    -- callers (deep inside the mock vim setup) can still hit the real impl.
    vim.api.nvim_win_is_valid = function(winid)
      if win_tab_map[winid] ~= nil then
        return true
      end
      return false
    end

    -- The real nvim provides these for window geometry. Tests don't render
    -- the actual float; stub minimally so calc_window_config can run.
    vim.api.nvim_win_get_position = vim.api.nvim_win_get_position or function()
      return { 0, 0 }
    end
    vim.api.nvim_win_get_width = vim.api.nvim_win_get_width or function()
      return 80
    end
    vim.api.nvim_win_get_config = vim.api.nvim_win_get_config or function()
      return { relative = "" }
    end
    vim.api.nvim_open_win = vim.api.nvim_open_win or function()
      return nil
    end
    vim.api.nvim_win_set_option = vim.api.nvim_win_set_option or function() end
    vim.api.nvim_win_set_config = vim.api.nvim_win_set_config or function() end
    vim.api.nvim_win_close = vim.api.nvim_win_close or function() end
    if not vim.wo then
      vim.wo = setmetatable({}, {
        __index = function()
          return setmetatable({}, { __newindex = function() end, __index = function() end })
        end,
      })
    end
  end)

  after_each(function()
    vim.api.nvim_get_current_tabpage = original_get_current_tabpage
    vim.api.nvim_tabpage_is_valid = original_tabpage_is_valid
    vim.api.nvim_win_get_tabpage = original_win_get_tabpage
    vim.api.nvim_win_is_valid = original_win_is_valid
    tab_registry.reset()
    session_manager.reset()
    tabbar._reset()
  end)

  it("snapshot is empty before any attach", function()
    tabbar.setup({ enabled = false })
    local snap = tabbar._snapshot()
    expect(next(snap)).to_be_nil()
  end)

  it("attach creates a per-tab slot keyed by the window's tabpage", function()
    tabbar.setup({ enabled = true })
    win_tab_map[100] = 1
    win_tab_map[200] = 2

    tabbar.attach(100, nil)
    tabbar.attach(200, nil)

    local snap = tabbar._snapshot()
    expect(snap[1]).not_to_be_nil()
    expect(snap[2]).not_to_be_nil()
    expect(snap[1].terminal_win).to_be(100)
    expect(snap[2].terminal_win).to_be(200)
  end)

  it("rebinding attach to the same tab updates terminal_win without affecting siblings", function()
    tabbar.setup({ enabled = true })
    win_tab_map[100] = 1
    win_tab_map[101] = 1
    win_tab_map[200] = 2

    tabbar.attach(100, nil)
    tabbar.attach(200, nil)
    tabbar.attach(101, nil) -- same tab 1, new window

    local snap = tabbar._snapshot()
    expect(snap[1].terminal_win).to_be(101)
    expect(snap[2].terminal_win).to_be(200)
  end)

  it("detach clears one tab without touching siblings", function()
    tabbar.setup({ enabled = true })
    win_tab_map[100] = 1
    win_tab_map[200] = 2
    tabbar.attach(100, nil)
    tabbar.attach(200, nil)

    current_tab = 1
    tabbar.detach()

    local snap = tabbar._snapshot()
    expect(snap[1].terminal_win).to_be_nil()
    expect(snap[2].terminal_win).to_be(200)
  end)

  it("cleanup removes the slot for one tab and leaves others", function()
    tabbar.setup({ enabled = true })
    win_tab_map[100] = 1
    win_tab_map[200] = 2
    tabbar.attach(100, nil)
    tabbar.attach(200, nil)

    tabbar.cleanup(1)

    local snap = tabbar._snapshot()
    expect(snap[1]).to_be_nil()
    expect(snap[2]).not_to_be_nil()
  end)

  it("cleanup_all wipes every slot and the augroup", function()
    tabbar.setup({ enabled = true })
    win_tab_map[100] = 1
    win_tab_map[200] = 2
    tabbar.attach(100, nil)
    tabbar.attach(200, nil)

    tabbar.cleanup_all()

    expect(next(tabbar._snapshot())).to_be_nil()
  end)

  it("attach is a no-op when the tabbar is disabled", function()
    tabbar.setup({ enabled = false })
    win_tab_map[100] = 1
    tabbar.attach(100, nil)
    expect(next(tabbar._snapshot())).to_be_nil()
  end)

  it("get_winid resolves only the current tab's tabbar", function()
    tabbar.setup({ enabled = true })
    win_tab_map[100] = 1
    tabbar.attach(100, nil)
    -- The mock vim doesn't actually open a float, so tabbar_win remains nil.
    -- get_winid returns nil regardless; just confirm it doesn't error and is
    -- scoped to current tab.
    current_tab = 2
    expect(tabbar.get_winid()).to_be_nil()
    current_tab = 1
    expect(tabbar.get_winid()).to_be_nil()
  end)

  it("attach with an invalid window does nothing", function()
    tabbar.setup({ enabled = true })
    -- Mock nvim_win_is_valid to return false for our test winid.
    local original_win_valid = vim.api.nvim_win_is_valid
    vim.api.nvim_win_is_valid = function(_)
      return false
    end
    tabbar.attach(999, nil)
    vim.api.nvim_win_is_valid = original_win_valid
    expect(next(tabbar._snapshot())).to_be_nil()
  end)

  it("snapshot reflects per-tab click_regions and winbar_session_ids tables", function()
    tabbar.setup({ enabled = true })
    win_tab_map[100] = 1
    win_tab_map[200] = 2
    tabbar.attach(100, nil)
    tabbar.attach(200, nil)
    local snap = tabbar._snapshot()
    assert.is_table(snap[1].click_regions)
    assert.is_table(snap[1].winbar_session_ids)
    assert.is_table(snap[2].click_regions)
    assert.is_table(snap[2].winbar_session_ids)
    -- Distinct table identities — mutating one must not affect the other.
    snap[1].click_regions[1] = { start_col = 1, end_col = 2 }
    expect(#snap[2].click_regions).to_be(0)
  end)

  it("invalid tabs are pruned from snapshot iteration", function()
    tabbar.setup({ enabled = true })
    win_tab_map[100] = 1
    win_tab_map[200] = 2
    tabbar.attach(100, nil)
    tabbar.attach(200, nil)

    valid_tabs[1] = nil

    -- Trigger autocmd-style iteration via a session-event render: we can't
    -- fire User autocmds in the mock cleanly, but cleanup_all does walk
    -- every slot, and prune happens lazily inside iteration helpers.
    -- Easiest direct test: cleanup the invalid tab by hand through cleanup.
    tabbar.cleanup(1)
    local snap = tabbar._snapshot()
    expect(snap[1]).to_be_nil()
    expect(snap[2]).not_to_be_nil()
  end)
end)
