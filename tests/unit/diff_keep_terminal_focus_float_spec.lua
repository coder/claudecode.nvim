require("tests.busted_setup")

-- Regression test for #150:
-- When diff_opts.keep_terminal_focus = true and the Claude terminal lives in a floating window,
-- opening a diff should return focus to the floating terminal (not the diff split behind it).

describe("Diff keep_terminal_focus with floating terminal", function()
  local diff

  local test_old_file = "/tmp/claudecode_keep_focus_old.txt"
  local test_new_file = "/tmp/claudecode_keep_focus_new.txt"
  local tab_name = "keep-focus-float"

  local editor_win = 1000
  local terminal_win = 1001
  local terminal_buf

  before_each(function()
    -- Fresh vim mock state
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end

    -- Ensure predictable tab/window state
    vim._tabs = { [1] = true }
    vim._current_tabpage = 1

    -- Reload diff module cleanly
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")

    -- Create a normal, non-floating editor window
    local editor_buf = vim.api.nvim_create_buf(true, false)
    vim._windows[editor_win] = { buf = editor_buf, width = 80 }
    vim._win_tab[editor_win] = 1

    -- Create a floating window for the terminal
    terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(terminal_buf, "buftype", "terminal")
    vim._windows[terminal_win] = {
      buf = terminal_buf,
      width = 80,
      config = { relative = "editor" },
    }
    vim._win_tab[terminal_win] = 1

    vim._tab_windows[1] = { editor_win, terminal_win }
    vim._current_window = terminal_win
    vim._next_winid = 1002

    -- Provide minimal config directly to diff module
    diff.setup({
      terminal = { split_side = "right", split_width_percentage = 0.30 },
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = true,
      },
    })

    -- Stub terminal provider with a valid terminal buffer
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return terminal_buf
      end,
      ensure_visible = function() end,
    }

    -- Create a real file so filereadable() returns 1 in mocks
    local f = io.open(test_old_file, "w")
    f:write("line1\nline2\n")
    f:close()

    -- Ensure a clean diff state
    diff._cleanup_all_active_diffs("test_setup")
  end)

  after_each(function()
    os.remove(test_old_file)
    os.remove(test_new_file)

    package.loaded["claudecode.terminal"] = nil

    if diff then
      diff._cleanup_all_active_diffs("test_teardown")
    end
  end)

  it("restores focus to floating terminal window after diff opens", function()
    local co = coroutine.create(function()
      diff.open_diff_blocking(test_old_file, test_new_file, "updated content\n", tab_name)
    end)

    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))
    assert.equal("suspended", coroutine.status(co))

    -- keep_terminal_focus uses vim.schedule; the vim mock executes scheduled callbacks immediately.

    -- Floating terminals (e.g. Snacks) should manage their own sizing.
    assert.equal(80, vim.api.nvim_win_get_width(terminal_win))
    assert.equal(terminal_win, vim.api.nvim_get_current_win())

    -- Resolve to finish the coroutine
    vim.schedule(function()
      diff._resolve_diff_as_rejected(tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end)
end)
