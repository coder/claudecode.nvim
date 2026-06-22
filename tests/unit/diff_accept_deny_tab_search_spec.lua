-- luacheck: globals expect
-- Tests for accept_current_diff / deny_current_diff tab-wide search fallback
require("tests.busted_setup")

describe("diff accept/deny tab-wide search", function()
  local diff

  before_each(function()
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.config"] = nil
    diff = require("claudecode.diff")
    diff.setup({})

    -- Reset mock state: one tab, one window showing buffer 1
    _G.vim._buffers = {
      [1] = { name = "/project/file.lua", lines = { "hello" }, options = {}, b_vars = {} },
    }
    _G.vim._windows = { [1000] = { buf = 1, width = 80 } }
    _G.vim._win_tab = { [1000] = 1 }
    _G.vim._tab_windows = { [1] = { 1000 } }
    _G.vim._tabs = { [1] = true }
    _G.vim._current_tabpage = 1
    _G.vim._current_window = 1000
    _G.vim._next_winid = 1001
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test_teardown")
  end)

  -- Helper: create a second buffer in the current tab with claudecode_diff_tab_name set
  local function add_diff_buffer_to_current_tab(tab_name)
    local diff_buf = #_G.vim._buffers + 1
    _G.vim._buffers[diff_buf] = {
      name = "/tmp/claudecode_diff_test.lua.new",
      lines = { "new content" },
      options = { eol = true },
      b_vars = { claudecode_diff_tab_name = tab_name },
    }
    local diff_win = _G.vim._next_winid
    _G.vim._next_winid = _G.vim._next_winid + 1
    _G.vim._windows[diff_win] = { buf = diff_buf, width = 80 }
    _G.vim._win_tab[diff_win] = 1
    table.insert(_G.vim._tab_windows[1], diff_win)
    return diff_buf, diff_win
  end

  describe("accept_current_diff", function()
    it("works when cursor is in the diff buffer", function()
      local tab_name = "test_accept_direct"
      local diff_buf, diff_win = add_diff_buffer_to_current_tab(tab_name)

      -- Simulate an active diff with a resolution callback
      -- Put cursor in diff buffer
      _G.vim._current_window = diff_win
      _G.vim.api.nvim_get_current_buf = function()
        return diff_buf
      end

      local found_buf = nil
      local orig_resolve = diff._resolve_diff_as_saved
      diff._resolve_diff_as_saved = function(tn, buf)
        found_buf = buf
        -- don't actually resolve, just capture
      end

      diff.accept_current_diff()

      diff._resolve_diff_as_saved = orig_resolve

      assert.equal(diff_buf, found_buf)
    end)

    it("falls back to searching the current tab when cursor is not in a diff buffer", function()
      local tab_name = "test_accept_fallback"
      local diff_buf, _ = add_diff_buffer_to_current_tab(tab_name)

      -- Cursor stays in the non-diff buffer (window 1000, buf 1)
      _G.vim._current_window = 1000
      _G.vim.api.nvim_get_current_buf = function()
        return 1 -- no claudecode_diff_tab_name
      end

      local found_buf = nil
      local orig_resolve = diff._resolve_diff_as_saved
      diff._resolve_diff_as_saved = function(tn, buf)
        found_buf = buf
      end

      diff.accept_current_diff()

      diff._resolve_diff_as_saved = orig_resolve

      assert.equal(diff_buf, found_buf)
    end)

    it("notifies when no diff buffer found in current tab", function()
      -- No diff buffer in the tab
      _G.vim._current_window = 1000
      _G.vim.api.nvim_get_current_buf = function()
        return 1
      end

      local notified = false
      local orig_notify = _G.vim.notify
      _G.vim.notify = function(msg, level)
        notified = true
        assert.is_not_nil(msg:find("No active diff"))
      end

      diff.accept_current_diff()

      _G.vim.notify = orig_notify
      assert.is_true(notified)
    end)
  end)

  describe("deny_current_diff", function()
    it("works when cursor is in the diff buffer", function()
      local tab_name = "test_deny_direct"
      local diff_buf, diff_win = add_diff_buffer_to_current_tab(tab_name)

      _G.vim._current_window = diff_win
      _G.vim.api.nvim_get_current_buf = function()
        return diff_buf
      end

      local resolved_name = nil
      local orig_resolve = diff._resolve_diff_as_rejected
      diff._resolve_diff_as_rejected = function(tn)
        resolved_name = tn
      end

      diff.deny_current_diff()

      diff._resolve_diff_as_rejected = orig_resolve
      assert.equal(tab_name, resolved_name)
    end)

    it("falls back to searching the current tab when cursor is not in a diff buffer", function()
      local tab_name = "test_deny_fallback"
      add_diff_buffer_to_current_tab(tab_name)

      -- Cursor in non-diff buffer
      _G.vim._current_window = 1000
      _G.vim.api.nvim_get_current_buf = function()
        return 1
      end

      local resolved_name = nil
      local orig_resolve = diff._resolve_diff_as_rejected
      diff._resolve_diff_as_rejected = function(tn)
        resolved_name = tn
      end

      diff.deny_current_diff()

      diff._resolve_diff_as_rejected = orig_resolve
      assert.equal(tab_name, resolved_name)
    end)

    it("notifies when no diff buffer found in current tab", function()
      _G.vim._current_window = 1000
      _G.vim.api.nvim_get_current_buf = function()
        return 1
      end

      local notified = false
      local orig_notify = _G.vim.notify
      _G.vim.notify = function(msg, level)
        notified = true
        assert.is_not_nil(msg:find("No active diff"))
      end

      diff.deny_current_diff()

      _G.vim.notify = orig_notify
      assert.is_true(notified)
    end)
  end)
end)
