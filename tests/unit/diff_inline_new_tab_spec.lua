require("tests.busted_setup")

-- Regression tests for the unified (inline) diff in a new tab.
--
-- With `layout = "unified"` and `open_in_new_tab`, diff_inline.setup_inline_diff
-- used to open the diff with `rightbelow vsplit` off the empty [No Name] window
-- that `:tabnew` creates. That window stayed in the tab as a blank pane beside
-- the diff. The diff now takes that window, unless it is the Claude terminal's.
describe("Unified diff in new tab", function()
  local open_diff_tool = require("claudecode.tools.open_diff")
  local diff = require("claudecode.diff")

  local test_old_file = "/tmp/claudecode_inline_newtab_old.txt"
  local test_new_file = "/tmp/claudecode_inline_newtab_new.txt"
  local test_tab_name = "inline-new-tab"
  local real_display_terminal_in_new_tab = diff._display_terminal_in_new_tab

  local function setup_config(hide_terminal_in_new_tab)
    diff.setup({
      terminal = { split_side = "right", split_width_percentage = 0.30 },
      diff_opts = {
        layout = "unified",
        open_in_new_tab = true,
        keep_terminal_focus = false,
        hide_terminal_in_new_tab = hide_terminal_in_new_tab,
      },
    })
  end

  local function open_diff()
    local params = {
      old_file_path = test_old_file,
      new_file_path = test_new_file,
      new_file_contents = "line1\nCHANGED\nline3\n",
      tab_name = test_tab_name,
    }
    local co = coroutine.create(function()
      open_diff_tool.handler(params)
    end)
    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))
    assert.equal("suspended", coroutine.status(co))
    return co
  end

  -- Windows in the diff's new tab, as { winid, bufnr } pairs.
  local function windows_in_new_tab(state)
    assert.is_not_nil(state.new_tab_number, "new_tab_number should be tracked, not nil")
    local wins = {}
    for _, w in ipairs(vim._tab_windows[state.new_tab_number] or {}) do
      wins[#wins + 1] = { win = w, buf = vim._windows[w] and vim._windows[w].buf }
    end
    return wins
  end

  before_each(function()
    local f = io.open(test_old_file, "w")
    f:write("line1\nline2\nline3\n")
    f:close()

    diff._cleanup_all_active_diffs("test_setup")

    -- Stub a valid terminal buffer so the new tab is created via :tabnew.
    local term_buf = vim.api.nvim_create_buf(false, true)
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return term_buf
      end,
      ensure_visible = function() end,
    }
  end)

  after_each(function()
    diff._display_terminal_in_new_tab = real_display_terminal_in_new_tab
    os.remove(test_old_file)
    os.remove(test_new_file)
    package.loaded["claudecode.terminal"] = nil
    diff._cleanup_all_active_diffs("test_teardown")
  end)

  it("reuses the ephemeral tabnew window (no empty pane) when terminal is hidden", function()
    setup_config(true)
    local co = open_diff()

    local state = diff._get_active_diffs()[test_tab_name]
    assert.is_table(state)
    assert.is_true(state.created_new_tab)

    local wins = windows_in_new_tab(state)
    -- Exactly one window: the diff itself, spanning the whole tab. Before the
    -- fix this was two (empty [No Name] pane + diff).
    assert.equal(1, #wins)
    assert.equal(state.new_buffer, wins[1].buf)

    vim.schedule(function()
      diff._resolve_diff_as_rejected(test_tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end)

  it("keeps only the diff and terminal (no empty pane) when terminal is shown", function()
    setup_config(false)
    local co = open_diff()

    local state = diff._get_active_diffs()[test_tab_name]
    assert.is_table(state)
    assert.is_true(state.created_new_tab)
    assert.is_not_nil(state.terminal_win_in_new_tab)

    local wins = windows_in_new_tab(state)
    -- Exactly two windows: diff + terminal. Before the fix this was three (the
    -- leftover ephemeral [No Name] pane, the terminal, and the diff).
    assert.equal(2, #wins)

    local buffers = {}
    for _, w in ipairs(wins) do
      buffers[w.buf] = true
    end
    assert.is_true(buffers[state.new_buffer], "diff buffer should be shown in the new tab")
    assert.is_true(
      buffers[vim._windows[state.terminal_win_in_new_tab].buf],
      "terminal buffer should be shown in the new tab"
    )

    vim.schedule(function()
      diff._resolve_diff_as_rejected(test_tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end)

  it("does not take the terminal's window when the new tab holds only the terminal", function()
    setup_config(false)
    local term_buf = vim.api.nvim_create_buf(false, true)
    -- A new tab whose only window is the Claude terminal's: there is no empty window to take.
    diff._display_terminal_in_new_tab = function()
      local original_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      local new_tab = vim.api.nvim_get_current_tabpage()
      local terminal_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(terminal_win, term_buf)
      return original_tab, terminal_win, false, new_tab
    end
    local co = open_diff()

    local state = diff._get_active_diffs()[test_tab_name]
    assert.is_table(state)
    local terminal_win = state.terminal_win_in_new_tab
    assert.is_not_nil(terminal_win)

    -- The terminal keeps its window, and the diff gets a window of its own beside it.
    assert.equal(term_buf, vim._windows[terminal_win].buf)
    assert.are_not.equal(terminal_win, state.new_window)
    assert.equal(state.new_buffer, vim._windows[state.new_window].buf)
    assert.equal(2, #windows_in_new_tab(state))

    vim.schedule(function()
      diff._resolve_diff_as_rejected(test_tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end)
end)
