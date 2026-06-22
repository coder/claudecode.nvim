-- Regression test for issue #277 (follow-up to the closeAllDiffTabs scoping fix):
--   When the current tab is made up entirely of foreign diff windows
--   (vimdiff / diffview.nvim / fugitive), find_main_editor_window() now returns
--   nil. The diff-setup fallback must NOT split that tab to host Claude's
--   proposal -- a tab has a single, shared diff set, so a same-tab split + the
--   subsequent `diffthis` would make Claude's diff join (and corrupt) the user's
--   existing diff. Instead the diff has to be opened in its own tab.
--
-- This was raised in review of the #277 fix: the &diff guard on
-- find_main_editor_window stops openDiff from `:edit`-ing INTO a foreign diff
-- window, but the terminal-only (#231) split fallback would still land Claude's
-- diff in the same tab. The fallback now routes to a new tab when the current
-- tab already hosts a diff.
require("tests.busted_setup")

-- Current tab (1) holds ONLY two diff windows (1000, 1001) and no plain editor
-- or terminal window, so find_main_editor_window() returns nil and the tab is
-- "all diff". _next_winid is advanced so create_split()/tabnew allocate fresh ids.
local function reset_to_all_diff_tab()
  assert(vim and vim._mock and vim._mock.reset, "expected vim mock with _mock.reset()")

  vim._mock.reset()
  vim._tabs = { [1] = true }
  vim._current_tabpage = 1
  vim._current_window = 1000
  vim._next_winid = 1002

  vim._mock.add_buffer(1, "/repo/a.lua", "a\nb\nc", { modified = false })
  vim._mock.add_buffer(2, "/repo/b.lua", "a\nX\nc", { modified = false })
  vim._mock.add_window(1000, 1, { 1, 0 })
  vim._mock.add_window(1001, 2, { 1, 0 })
  -- Both windows are in diff mode: the user's vimdiff/diffview review.
  vim.api.nvim_win_set_option(1000, "diff", true)
  vim.api.nvim_win_set_option(1001, "diff", true)
  vim._win_tab[1000] = 1
  vim._win_tab[1001] = 1
  vim._tab_windows[1] = { 1000, 1001 }
end

describe("Diff when the current tab is all foreign diff windows (issue #277)", function()
  local diff

  before_each(function()
    reset_to_all_diff_tab()

    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }
    -- Stub the terminal module so display_terminal_in_new_tab() takes its simple
    -- `:tabnew` path (no active Claude terminal to relocate).
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return nil
      end,
    }

    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")

    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false, -- the path that used to split the foreign diff tab
        keep_terminal_focus = false,
        on_new_file_reject = "keep_empty",
      },
      terminal = {},
    })
  end)

  after_each(function()
    if diff and diff._cleanup_all_active_diffs then
      diff._cleanup_all_active_diffs("test teardown")
    end
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.terminal"] = nil
  end)

  it("detects that the current tab hosts a diff (precondition)", function()
    expect(diff._find_main_editor_window()).to_be(nil)
    expect(diff._current_tab_has_diff_window()).to_be(true)
  end)

  it("opens the diff in a NEW tab instead of splitting the foreign diff tab", function()
    local tab_name = "✻ [Claude Code] a.lua (445ca6) ⧉"
    local params = {
      old_file_path = "/repo/a.lua",
      new_file_path = "/repo/a.lua",
      new_file_contents = "a\nPROPOSED\nc\n",
      tab_name = tab_name,
    }

    local setup_ok, setup_err = pcall(function()
      diff._setup_blocking_diff(params, function() end)
    end)
    assert.is_true(setup_ok, "diff setup should not error in an all-diff tab: " .. tostring(setup_err))

    local state = diff._get_active_diffs()[tab_name]
    assert.is_table(state)
    -- The fix: the diff was isolated in its own tab rather than split into the
    -- user's diff tab. created_new_tab proves the new-tab route was taken; no
    -- same-tab fallback split window was created.
    assert.is_true(state.created_new_tab)
    assert.is_nil(state.fallback_window)
    assert.is_number(state.new_tab_number)
    assert.are_not.equal(1, state.new_tab_number)

    -- The user's original diff windows are left untouched in tab 1.
    assert.is_true(vim.api.nvim_win_is_valid(1000))
    assert.is_true(vim.api.nvim_win_is_valid(1001))
  end)

  it("returns false from the detector when the tab has no diff window", function()
    -- Flip both windows out of diff mode: now an ordinary multi-split tab.
    vim.api.nvim_win_set_option(1000, "diff", false)
    vim.api.nvim_win_set_option(1001, "diff", false)
    expect(diff._current_tab_has_diff_window()).to_be(false)
    -- With a non-diff editor window available, the finder selects it (no fallback).
    expect(diff._find_main_editor_window()).to_be(1000)
  end)
end)
