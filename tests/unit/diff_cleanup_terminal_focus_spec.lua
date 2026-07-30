require("tests.busted_setup")

-- Regression test: accepting a same-tab diff via `:w` (BufWriteCmd ->
-- _resolve_diff_as_saved, then Claude's close_tab tool -> _cleanup_diff_state)
-- should return focus to the Claude terminal window afterward when
-- diff_opts.keep_terminal_focus is enabled, instead of leaving Neovim's
-- default post-window-close selection to land anywhere.

describe("Diff cleanup terminal focus (same-tab)", function()
  local diff
  local test_old_file = "/tmp/test_cleanup_terminal_focus_old.txt"
  local tab_name = "test_cleanup_terminal_focus_tab"

  local editor_win = 1000
  local terminal_win = 1001
  local terminal_buf

  local function reset_vim_state()
    assert(vim and vim._mock and vim._mock.reset, "Expected vim mock with _mock.reset()")
    vim._mock.reset()

    vim._tabs = { [1] = true }
    vim._current_tabpage = 1
    vim._current_window = editor_win
    vim._next_winid = 1002

    vim._mock.add_buffer(1, "/home/user/project/test.lua", "local test = {}\nreturn test", { modified = false })
    vim._mock.add_window(editor_win, 1, { 1, 0 })
    vim._win_tab[editor_win] = 1
    vim._tab_windows[1] = { editor_win }
  end

  local function add_terminal_window()
    terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(terminal_buf, "buftype", "terminal")
    vim._mock.add_window(terminal_win, terminal_buf, { 1, 0 })
    vim._win_tab[terminal_win] = 1
    table.insert(vim._tab_windows[1], terminal_win)
  end

  before_each(function()
    reset_vim_state()
    add_terminal_window()

    local f = assert(io.open(test_old_file, "w"))
    f:write("line1\nline2\n")
    f:close()

    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }

    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return terminal_buf
      end,
      ensure_visible = function() end,
    }

    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
  end)

  after_each(function()
    os.remove(test_old_file)
    package.loaded["claudecode.terminal"] = nil
    if diff and diff._cleanup_all_active_diffs then
      diff._cleanup_all_active_diffs("test teardown")
    end
    package.loaded["claudecode.diff"] = nil
  end)

  it("refocuses the claude terminal window when keep_terminal_focus is enabled", function()
    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = true,
      },
      terminal = {},
    })

    local params = {
      old_file_path = test_old_file,
      new_file_path = test_old_file,
      new_file_contents = "new1\nnew2\n",
      tab_name = tab_name,
    }

    diff._setup_blocking_diff(params, function() end)

    local state = diff._get_active_diffs()[tab_name]
    assert.is_table(state)

    -- Simulate the user's cursor being in the diff buffer when they run :w.
    vim.api.nvim_set_current_win(state.new_window)

    -- BufWriteCmd -> _resolve_diff_as_saved, then Claude's close_tab tool call -> _cleanup_diff_state.
    diff._resolve_diff_as_saved(tab_name, state.new_buffer)
    diff._cleanup_diff_state(tab_name, "accepted via :w")

    assert.is_false(vim.api.nvim_win_is_valid(state.new_window))
    assert.equal(terminal_win, vim.api.nvim_get_current_win())
  end)

  it("leaves focus untouched when keep_terminal_focus is disabled (default)", function()
    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = false,
      },
      terminal = {},
    })

    local params = {
      old_file_path = test_old_file,
      new_file_path = test_old_file,
      new_file_contents = "new1\nnew2\n",
      tab_name = tab_name,
    }

    diff._setup_blocking_diff(params, function() end)

    local state = diff._get_active_diffs()[tab_name]
    vim.api.nvim_set_current_win(state.new_window)

    local win_before_cleanup = vim.api.nvim_get_current_win()
    diff._resolve_diff_as_saved(tab_name, state.new_buffer)
    diff._cleanup_diff_state(tab_name, "accepted via :w")

    -- No explicit refocus should have happened; the current window is whatever
    -- it was left as (this plugin's existing, unchanged default behavior).
    assert.equal(win_before_cleanup, vim.api.nvim_get_current_win())
  end)

  it("does not error when no claude terminal window is visible", function()
    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = true,
      },
      terminal = {},
    })

    package.loaded["claudecode.terminal"].get_active_terminal_bufnr = function()
      return nil
    end

    local params = {
      old_file_path = test_old_file,
      new_file_path = test_old_file,
      new_file_contents = "new1\nnew2\n",
      tab_name = tab_name,
    }

    diff._setup_blocking_diff(params, function() end)

    local state = diff._get_active_diffs()[tab_name]
    vim.api.nvim_set_current_win(state.new_window)
    diff._resolve_diff_as_saved(tab_name, state.new_buffer)

    assert.has_no.errors(function()
      diff._cleanup_diff_state(tab_name, "accepted via :w")
    end)
  end)
end)
