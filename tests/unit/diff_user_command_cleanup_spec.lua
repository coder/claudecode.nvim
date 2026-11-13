require("tests.busted_setup")

local function reset_vim_state()
  assert(vim and vim._mock and vim._mock.reset, "Expected vim mock with _mock.reset()")

  vim._mock.reset()

  vim._tabs = { [1] = true }
  vim._current_tabpage = 1
  vim._current_window = 1000
  vim._next_winid = 1001

  vim._mock.add_buffer(1, "/home/user/project/test.lua", "local test = {}\nreturn test", { modified = false })
  vim._mock.add_window(1000, 1, { 1, 0 })
  vim._win_tab[1000] = 1
  vim._tab_windows[1] = { 1000 }
end

describe("Diff user command cleanup (accept/deny)", function()
  local diff
  local test_old_file = "/tmp/test_user_command_cleanup_old.txt"
  local tab_name = "test_user_command_cleanup_tab"

  before_each(function()
    reset_vim_state()

    local f = assert(io.open(test_old_file, "w"))
    f:write("line1\nline2\n")
    f:close()

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

  it("accept_current_diff cleans up windows and removes diff state", function()
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
    local new_buffer = state.new_buffer

    -- Make the proposed buffer current so accept_current_diff can read the
    -- buffer-local tab_name marker.
    vim.api.nvim_set_current_buf(new_buffer)

    diff.accept_current_diff()

    -- After accept, windows must be closed and state must be cleared.
    assert.is_false(vim.api.nvim_win_is_valid(new_win))
    assert.is_nil(diff._get_active_diffs()[tab_name])
  end)

  it("deny_current_diff cleans up windows and removes diff state", function()
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
    local new_buffer = state.new_buffer

    vim.api.nvim_set_current_buf(new_buffer)

    diff.deny_current_diff()

    assert.is_false(vim.api.nvim_win_is_valid(new_win))
    assert.is_nil(diff._get_active_diffs()[tab_name])
  end)

  it("accept_current_diff is a no-op when buffer has no diff marker", function()
    -- No diff registered; current buffer is a plain non-diff buffer.
    diff.accept_current_diff()
    -- Should not raise; no diffs should be present.
    local diffs = diff._get_active_diffs()
    assert.is_table(diffs)
    assert.is_nil(next(diffs))
  end)
end)
