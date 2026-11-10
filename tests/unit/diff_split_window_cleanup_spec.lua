require("tests.busted_setup")
local temp_dir = require("tests.helpers.temp_dir")

local function reset_vim_state_for_splits()
  assert(vim and vim._mock and vim._mock.reset, "Expected vim mock with _mock.reset()")

  vim._mock.reset()

  -- Recreate a minimal tab/window state suitable for split operations.
  vim._tabs = { [1] = true }
  vim._current_tabpage = 1
  vim._current_window = 1000
  vim._next_winid = 1001

  vim._mock.add_buffer(1, "/home/user/project/test.lua", "local test = {}\nreturn test", { modified = false })
  vim._mock.add_window(1000, 1, { 1, 0 })
  vim._win_tab[1000] = 1
  vim._tab_windows[1] = { 1000 }
end

describe("Diff split window cleanup", function()
  local diff
  local dir, test_old_file
  setup(function()
    dir = temp_dir.new()
    test_old_file = dir .. "/test_split_window_cleanup_old.txt"
  end)
  teardown(function()
    temp_dir.remove(dir)
  end)
  local tab_name = "test_split_window_cleanup_tab"

  before_each(function()
    reset_vim_state_for_splits()

    -- Prepare a dummy file
    local f = assert(io.open(test_old_file, "w"))
    f:write("line1\nline2\n")
    f:close()

    -- Minimal logger stub
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }

    -- Reload diff module cleanly
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")

    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = false,
      },
      terminal = {},
    })
  end)

  after_each(function()
    os.remove(test_old_file)
    if diff and diff._cleanup_all_active_diffs then
      diff._cleanup_all_active_diffs("test teardown")
    end
    package.loaded["claudecode.diff"] = nil
  end)

  it("closes the plugin-created original split after accept when close_tab is invoked", function()
    local params = {
      old_file_path = test_old_file,
      new_file_path = test_old_file,
      new_file_contents = "new1\nnew2\n",
      tab_name = tab_name,
    }

    diff._setup_blocking_diff(params, function() end)

    local state = diff._get_active_diffs()[tab_name]
    assert.is_table(state)

    local new_win = state.new_window
    local target_win = state.target_window

    -- Should have created an extra split for the original side (target_win != 1000)
    assert.are_not.equal(1000, target_win)
    assert.is_true(vim.api.nvim_win_is_valid(target_win))
    assert.is_true(vim.api.nvim_win_is_valid(new_win))

    diff._resolve_diff_as_saved(tab_name, state.new_buffer)

    -- Accept should not close windows yet
    assert.is_true(vim.api.nvim_win_is_valid(target_win))

    local closed = diff.close_diff_by_tab_name(tab_name)
    assert.is_true(closed)

    assert.is_false(vim.api.nvim_win_is_valid(new_win))
    assert.is_false(vim.api.nvim_win_is_valid(target_win))
    assert.is_true(vim.api.nvim_win_is_valid(1000))
  end)

  it("does not build the diff in the preview window when it shows the old file", function()
    vim._mock.add_buffer(2, test_old_file, "line1\nline2\n", { modified = false })
    vim._mock.add_window(1001, 2, { 1, 0 })
    vim._windows[1001].options = { previewwindow = true }
    vim._win_tab[1001] = 1
    vim._tab_windows[1] = { 1001, 1000 }
    vim._next_winid = 1002

    diff._setup_blocking_diff({
      old_file_path = test_old_file,
      new_file_path = test_old_file,
      new_file_contents = "new content\n",
      tab_name = tab_name,
    }, function() end)

    local state = diff._get_active_diffs()[tab_name]
    assert.is_table(state)
    assert.are_not.equal(1001, state.target_window)
    assert.are_not.equal(1001, state.new_window)
    assert.are.equal(2, vim.api.nvim_win_get_buf(1001))
    assert.is_falsy(vim.api.nvim_win_get_option(1001, "diff"))
  end)

  it("does not close the reused target window when the old file is already open", function()
    -- Open the old file in the main window so choose_original_window reuses it
    vim.cmd("edit " .. vim.fn.fnameescape(test_old_file))

    local params = {
      old_file_path = test_old_file,
      new_file_path = test_old_file,
      new_file_contents = "new content\n",
      tab_name = tab_name,
    }

    diff._setup_blocking_diff(params, function() end)

    local state = diff._get_active_diffs()[tab_name]
    assert.is_table(state)

    local new_win = state.new_window
    local target_win = state.target_window

    assert.are.equal(1000, target_win)
    assert.is_true(vim.api.nvim_win_is_valid(new_win))

    diff._resolve_diff_as_saved(tab_name, state.new_buffer)

    local closed = diff.close_diff_by_tab_name(tab_name)
    assert.is_true(closed)

    assert.is_false(vim.api.nvim_win_is_valid(new_win))
    assert.is_true(vim.api.nvim_win_is_valid(1000))

    -- In reuse scenario, diff mode should have been disabled.
    assert.are.equal("diffoff", vim._last_command)
  end)
end)
