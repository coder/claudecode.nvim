-- Regression test for issue #231:
--   "When the Claude Code terminal is the only window (no other splits), an
--    error is generated when Claude tries to suggest changes."
--   https://github.com/coder/claudecode.nvim/issues/231
--
-- Before the fix, M._setup_blocking_diff errored with "No suitable editor window
-- found" whenever find_main_editor_window() returned nil (e.g. the only window
-- is a terminal). The fix creates a split + fresh buffer to host the diff, tracks
-- that window as `fallback_window`, and closes it on cleanup so it is not leaked.
require("tests.busted_setup")

-- Build a consistent mock window model where the ONLY window (1000) is a terminal,
-- so find_main_editor_window() returns nil -- the issue #231 layout. (_next_winid is
-- advanced past 1000 so create_split() allocates fresh window ids without colliding.)
local function reset_to_terminal_only()
  assert(vim and vim._mock and vim._mock.reset, "expected vim mock with _mock.reset()")

  vim._mock.reset()
  vim._tabs = { [1] = true }
  vim._current_tabpage = 1
  vim._current_window = 1000
  vim._next_winid = 1001

  vim._mock.add_buffer(1, "term://fake/claude", "", { buftype = "terminal", modified = false })
  vim._mock.add_window(1000, 1, { 1, 0 })
  vim._win_tab[1000] = 1
  vim._tab_windows[1] = { 1000 }
end

describe("Diff with the Claude terminal as the only window (issue #231)", function()
  local diff

  before_each(function()
    reset_to_terminal_only()

    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }

    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")

    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false, -- default: the path that used to error
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
  end)

  it("has no suitable editor window in this layout (root-cause precondition)", function()
    expect(diff._find_main_editor_window()).to_be(nil)
  end)

  it("creates a window for the diff instead of erroring, then cleans it up (new file)", function()
    local tab_name = "✻ [Claude Code] INSTALL.md (445ca6) ⧉"
    local params = {
      old_file_path = "/nonexistent/INSTALL.md", -- new file (matches the issue)
      new_file_path = "/nonexistent/INSTALL.md",
      new_file_contents = "# Install\n\nproposed by Claude\n",
      tab_name = tab_name,
    }

    -- The regression: this used to raise "No suitable editor window found".
    local setup_ok, setup_err = pcall(function()
      diff._setup_blocking_diff(params, function() end)
    end)
    assert.is_true(setup_ok, "diff setup should not error in a terminal-only layout: " .. tostring(setup_err))

    local state = diff._get_active_diffs()[tab_name]
    assert.is_table(state)
    assert.is_true(vim.api.nvim_buf_is_valid(state.new_buffer))

    -- The plugin had to create a window to host the diff (none existed). It must be recorded as
    -- `fallback_window` (distinct from the terminal) so cleanup can close it.
    assert.is_number(state.fallback_window)
    assert.are_not.equal(1000, state.fallback_window)
    assert.is_true(vim.api.nvim_win_is_valid(state.fallback_window))
    local fallback_buf = vim.api.nvim_win_get_buf(state.fallback_window)

    -- Cleanup must close the plugin-created fallback window (leaving the terminal, 1000) and wipe
    -- its throwaway scratch buffer. Regression guard for the window + buffer leak (the host window
    -- was left open and the scratch buffer left behind on every terminal-only diff).
    diff._cleanup_diff_state(tab_name, "test cleanup")
    assert.is_false(vim.api.nvim_win_is_valid(state.fallback_window))
    assert.is_false(vim.api.nvim_buf_is_valid(fallback_buf))
    assert.is_true(vim.api.nvim_win_is_valid(1000))
  end)

  -- If setup errors after the fallback window + proposed buffer are created but before the diff
  -- state is registered, the error handler must still clean them up (not covered by state cleanup).
  it("cleans up the fallback window and proposed buffer when setup errors before registration", function()
    -- Force a failure after the fallback split is created (winid 1001) but before registration.
    diff._create_diff_view_from_window = function()
      error({ code = -32000, message = "boom" })
    end

    local bufs_before = #vim.api.nvim_list_bufs()
    local tab_name = "✻ [Claude Code] err.md ⧉"
    local ok = pcall(function()
      diff._setup_blocking_diff({
        old_file_path = "/nonexistent/err.md",
        new_file_path = "/nonexistent/err.md",
        new_file_contents = "x\n",
        tab_name = tab_name,
      }, function() end)
    end)

    assert.is_false(ok) -- setup is expected to fail
    assert.is_nil(diff._get_active_diffs()[tab_name]) -- no diff state registered
    assert.is_false(vim.api.nvim_win_is_valid(1001)) -- the stranded fallback split was closed
    assert.is_true(vim.api.nvim_win_is_valid(1000)) -- the terminal window survives
    assert.equals(bufs_before, #vim.api.nvim_list_bufs()) -- proposed buffer + scratch not leaked
  end)
end)
