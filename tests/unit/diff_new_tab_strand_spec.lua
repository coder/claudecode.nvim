-- Regression test for issue #262:
--   "diff: open_in_new_tab can strand a tab if setup errors before the diff
--    state is registered"
--   https://github.com/coder/claudecode.nvim/issues/262
--
-- With diff_opts.open_in_new_tab = true, M._setup_blocking_diff calls
-- display_terminal_in_new_tab() early (it runs `:tabnew`). If setup then throws
-- before M._register_diff_state runs, the pre-registration cleanup branch must
-- close that stranded tab and refocus the original one -- mirroring how #260
-- handles the fallback window / proposed buffer on the same error path.
--
-- Before the fix, `new_tab_handle` was declared inside the pcall closure, so the
-- error handler could not reach it: one extra tab was stranded per failed setup
-- and focus was left on it.
require("tests.busted_setup")

local function count_tabs()
  local n = 0
  for _ in pairs(vim._tabs) do
    n = n + 1
  end
  return n
end

describe("Diff open_in_new_tab cleanup on early setup error (issue #262)", function()
  local diff

  before_each(function()
    -- Start from a single, clean tab/window model.
    vim._mock.reset()
    vim._tabs = { [1] = true }
    vim._current_tabpage = 1
    vim._current_window = 1000
    vim._next_winid = 1001
    vim._mock.add_buffer(1, "/home/user/project/test.lua", "local x = 1\n")
    vim._mock.add_window(1000, 1, { 1, 0 })
    vim._win_tab[1000] = 1
    vim._tab_windows[1] = { 1000 }

    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }

    -- Stub the terminal provider with a valid terminal buffer so the
    -- open_in_new_tab path is exercised as in real usage.
    local term_buf = vim.api.nvim_create_buf(false, true)
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return term_buf
      end,
      ensure_visible = function() end,
    }

    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = true,
        -- Return right after `:tabnew` (skip the terminal vsplit) so the test
        -- targets the tab leak itself, not terminal-split window plumbing.
        hide_terminal_in_new_tab = true,
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

  it("creates exactly one new tab on the open_in_new_tab path (precondition)", function()
    -- Sanity: when setup SUCCEEDS, a tab is created and then cleaned up. This
    -- proves the harness/mock models tab creation+teardown, so the leak assertion
    -- below is meaningful.
    local tab_name = "✻ [Claude Code] ok.md ⧉"
    local tabs_before = count_tabs()
    local ok = pcall(function()
      diff._setup_blocking_diff({
        old_file_path = "/nonexistent/ok.md",
        new_file_path = "/nonexistent/ok.md",
        new_file_contents = "hello\n",
        tab_name = tab_name,
      }, function() end)
    end)
    assert.is_true(ok)
    assert.is_table(diff._get_active_diffs()[tab_name])
    assert.is_true(count_tabs() > tabs_before) -- a tab was created
    diff._cleanup_diff_state(tab_name, "precondition cleanup")
    assert.equals(tabs_before, count_tabs()) -- and cleaned up
  end)

  it("does not strand a tab when setup errors before the diff state is registered", function()
    -- Force a failure AFTER display_terminal_in_new_tab() ran `:tabnew` but
    -- BEFORE _register_diff_state.
    diff._create_diff_view_from_window = function()
      error({ code = -32000, message = "boom (before registration, after tabnew)" })
    end

    local tabs_before = count_tabs()
    local original_tab = vim.api.nvim_get_current_tabpage()
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
    -- The bug: the `:tabnew` tab is left open. After the fix, the error handler
    -- closes it, so the tab count returns to baseline...
    assert.equals(tabs_before, count_tabs())
    -- ...and focus is restored to the original tab (not left on the stranded one).
    assert.is_true(vim.api.nvim_tabpage_is_valid(original_tab))
    assert.equals(original_tab, vim.api.nvim_get_current_tabpage())
  end)

  -- display_terminal_in_new_tab() runs `:tabnew` and only THEN does its window setup. If that
  -- setup throws (e.g. a vsplit/window failure), Lua's multiple-assignment leaves new_tab_handle
  -- unassigned -- so the error handler can't rely on the returned handle. It must fall back to the
  -- current tab (which is still the just-created one). Regression guard for that deeper case.
  it("does not strand a tab when display_terminal_in_new_tab throws after :tabnew", function()
    -- Do NOT hide the terminal, so the helper proceeds past `:tabnew` into the window setup, then
    -- force the first nvim_win_set_buf (inside the helper, after the tab is created) to throw.
    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = true,
        hide_terminal_in_new_tab = false,
        on_new_file_reject = "keep_empty",
      },
      terminal = {},
    })

    local real_set_buf = vim.api.nvim_win_set_buf
    local threw = false
    vim.api.nvim_win_set_buf = function(...)
      if not threw then
        threw = true
        error("simulated post-tabnew failure inside display_terminal_in_new_tab")
      end
      return real_set_buf(...)
    end

    local tabs_before = count_tabs()
    local original_tab = vim.api.nvim_get_current_tabpage()
    local tab_name = "✻ [Claude Code] helper-throw.md ⧉"

    local ok = pcall(function()
      diff._setup_blocking_diff({
        old_file_path = "/nonexistent/helper-throw.md",
        new_file_path = "/nonexistent/helper-throw.md",
        new_file_contents = "x\n",
        tab_name = tab_name,
      }, function() end)
    end)

    vim.api.nvim_win_set_buf = real_set_buf

    assert.is_true(threw) -- the injected failure actually fired inside the helper
    assert.is_false(ok)
    assert.is_nil(diff._get_active_diffs()[tab_name])
    -- The tab was created inside the helper (new_tab_handle never returned); the current-tab
    -- fallback must still close it and restore focus.
    assert.equals(tabs_before, count_tabs())
    assert.is_true(vim.api.nvim_tabpage_is_valid(original_tab))
    assert.equals(original_tab, vim.api.nvim_get_current_tabpage())
  end)
end)
